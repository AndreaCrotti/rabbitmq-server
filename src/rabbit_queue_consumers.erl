%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_queue_consumers).

-export([new/0, max_active_priority/1, inactive/1, all/1, count/0,
         unacknowledged_message_count/0, add/9, remove/3, erase_ch/2,
         send_drained/0, deliver/3, record_ack/3, subtract_acks/2,
         possibly_unblock/3,
         resume_fun/0, notify_sent_fun/1, activate_limit_fun/0, credit_fun/4,
         utilisation/1]).

%%----------------------------------------------------------------------------

-define(UNSENT_MESSAGE_LIMIT,          200).

-record(state, {consumers, use}).

-record(consumer, {tag, ack_required, args}).

%% These are held in our process dictionary
-record(cr, {ch_pid,
             monitor_ref,
             acktags,
             consumer_count,
             %% Queue of {ChPid, #consumer{}} for consumers which have
             %% been blocked for any reason
             blocked_consumers,
             %% The limiter itself
             limiter,
             %% Internal flow control for queue -> writer
             unsent_message_count}).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type time_micros() :: non_neg_integer().
-type ratio() :: float().
-type state() :: #state{consumers ::priority_queue:q(),
                        use       :: {'inactive',
                                      time_micros(), time_micros(), ratio()} |
                                     {'active', time_micros(), ratio()}}.
-type ch() :: pid().
-type ack() :: non_neg_integer().
-type cr_fun() :: fun ((#cr{}) -> #cr{}).
-type credit_args() :: {non_neg_integer(), boolean()} | 'none'.
-type fetch_result() :: {rabbit_types:basic_message(), boolean(), ack()}.

-spec new() -> state().
-spec max_active_priority(state()) -> integer() | 'infinity' | 'empty'.
-spec inactive(state()) -> boolean().
-spec all(state()) -> [{ch(), rabbit_types:ctag(), boolean(),
                        rabbit_framing:amqp_table()}].
-spec count() -> non_neg_integer().
-spec unacknowledged_message_count() -> non_neg_integer().
-spec add(ch(), rabbit_types:ctag(), boolean(), pid(), boolean(),
          credit_args(), rabbit_framing:amqp_table(), boolean(),
          state()) -> state().
-spec remove(ch(), rabbit_types:ctag(), state()) ->
                    'not_found' | state().
-spec erase_ch(ch(), state()) ->
                      'not_found' | {[ack()], [rabbit_types:ctag()],
                                     state()}.
-spec send_drained() -> 'ok'.
-spec deliver(fun ((boolean()) -> {fetch_result(), T}),
              rabbit_amqqueue:name(), state()) ->
                     {'delivered', [{ch(), rabbit_types:ctag()}], T, state()} |
                     {'undelivered', [{ch(), rabbit_types:ctag()}], state()}.
-spec record_ack(ch(), pid(), ack()) -> 'ok'.
-spec subtract_acks(ch(), [ack()]) -> 'not_found' | 'ok'.
-spec possibly_unblock(cr_fun(), ch(), state()) ->
                              'unchanged' |
                              {'unblocked', [rabbit_types:ctag()], state()}.
-spec resume_fun()                                        -> cr_fun().
-spec notify_sent_fun(non_neg_integer())                  -> cr_fun().
-spec activate_limit_fun()                                -> cr_fun().
-spec credit_fun(boolean(), non_neg_integer(), boolean(),
                 rabbit_types:ctag())                     -> cr_fun().
-spec utilisation(state()) -> ratio().

-endif.

%%----------------------------------------------------------------------------

new() -> #state{consumers = priority_queue:new(),
                use       = {inactive, now_micros(), 0, 0.0}}.

max_active_priority(#state{consumers = Consumers}) ->
    priority_queue:highest(Consumers).

inactive(#state{consumers = Consumers}) ->
    priority_queue:is_empty(Consumers).

all(#state{consumers = Consumers}) ->
    lists:foldl(fun (C, Acc) -> consumers(C#cr.blocked_consumers, Acc) end,
                consumers(Consumers, []), all_ch_record()).

consumers(Consumers, Acc) ->
    priority_queue:fold(
      fun ({ChPid, Consumer}, _P, Acc1) ->
              #consumer{tag = CTag, ack_required = Ack, args = Args} = Consumer,
              [{ChPid, CTag, Ack, Args} | Acc1]
      end, Acc, Consumers).

count() -> lists:sum([Count || #cr{consumer_count = Count} <- all_ch_record()]).

unacknowledged_message_count() ->
    lists:sum([queue:len(C#cr.acktags) || C <- all_ch_record()]).

add(ChPid, ConsumerTag, NoAck, LimiterPid, LimiterActive, CreditArgs, OtherArgs,
    IsEmpty, State = #state{consumers = Consumers}) ->
    C = #cr{consumer_count = Count,
            limiter        = Limiter} = ch_record(ChPid, LimiterPid),
    Limiter1 = case LimiterActive of
                   true  -> rabbit_limiter:activate(Limiter);
                   false -> Limiter
               end,
    Limiter2 = case CreditArgs of
                   none         -> Limiter1;
                   {Crd, Drain} -> rabbit_limiter:credit(
                                     Limiter1, ConsumerTag, Crd, IsEmpty, Drain)
               end,
    C1 = C#cr{consumer_count = Count + 1,
              limiter        = Limiter2},
    update_ch_record(case IsEmpty of
                         true  -> send_drained(C1);
                         false -> C1
                     end),
    Consumer = #consumer{tag          = ConsumerTag,
                         ack_required = not NoAck,
                         args         = OtherArgs},
    State#state{consumers = add_consumer({ChPid, Consumer}, Consumers)}.

remove(ChPid, ConsumerTag, State = #state{consumers = Consumers}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{consumer_count    = Count,
                limiter           = Limiter,
                blocked_consumers = Blocked} ->
            Blocked1 = remove_consumer(ChPid, ConsumerTag, Blocked),
            Limiter1 = case Count of
                           1 -> rabbit_limiter:deactivate(Limiter);
                           _ -> Limiter
                       end,
            Limiter2 = rabbit_limiter:forget_consumer(Limiter1, ConsumerTag),
            update_ch_record(C#cr{consumer_count    = Count - 1,
                                  limiter           = Limiter2,
                                  blocked_consumers = Blocked1}),
            State#state{consumers =
                            remove_consumer(ChPid, ConsumerTag, Consumers)}
    end.

erase_ch(ChPid, State = #state{consumers = Consumers}) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{ch_pid            = ChPid,
                acktags           = ChAckTags,
                blocked_consumers = BlockedQ} ->
            AllConsumers = priority_queue:join(Consumers, BlockedQ),
            ok = erase_ch_record(C),
            {queue:to_list(ChAckTags),
             tags(priority_queue:to_list(AllConsumers)),
             State#state{consumers = remove_consumers(ChPid, Consumers)}}
    end.

send_drained() -> [update_ch_record(send_drained(C)) || C <- all_ch_record()],
                  ok.

deliver(FetchFun, QName, State) ->
    deliver(FetchFun, QName, [], State).

deliver(FetchFun, QName, Blocked, State = #state{consumers = Consumers}) ->
    case priority_queue:out_p(Consumers) of
        {empty, _} ->
            {undelivered, Blocked,
             State#state{use = update_use(State#state.use, inactive)}};
        {{value, QEntry = {ChPid, Consumer}, Priority}, Tail} ->
            case deliver_to_consumer(FetchFun, QEntry, QName) of
                {delivered, R} ->
                    {delivered, Blocked, R,
                     State#state{consumers = priority_queue:in(QEntry, Priority,
                                                               Tail)}};
                undelivered ->
                    deliver(FetchFun, QName,
                            [{ChPid, Consumer#consumer.tag} | Blocked],
                            State#state{consumers = Tail})
            end
    end.

deliver_to_consumer(FetchFun, E = {ChPid, Consumer}, QName) ->
    C = lookup_ch(ChPid),
    case is_ch_blocked(C) of
        true  -> block_consumer(C, E),
                 undelivered;
        false -> case rabbit_limiter:can_send(C#cr.limiter,
                                              Consumer#consumer.ack_required,
                                              Consumer#consumer.tag) of
                     {suspend, Limiter} ->
                         block_consumer(C#cr{limiter = Limiter}, E),
                         undelivered;
                     {continue, Limiter} ->
                         {delivered, deliver_to_consumer(
                                       FetchFun, Consumer,
                                       C#cr{limiter = Limiter}, QName)}
                 end
    end.

deliver_to_consumer(FetchFun,
                    #consumer{tag          = ConsumerTag,
                              ack_required = AckRequired},
                    C = #cr{ch_pid               = ChPid,
                            acktags              = ChAckTags,
                            unsent_message_count = Count},
                    QName) ->
    {{Message, IsDelivered, AckTag}, R} = FetchFun(AckRequired),
    rabbit_channel:deliver(ChPid, ConsumerTag, AckRequired,
                           {QName, self(), AckTag, IsDelivered, Message}),
    ChAckTags1 = case AckRequired of
                     true  -> queue:in(AckTag, ChAckTags);
                     false -> ChAckTags
                 end,
    update_ch_record(C#cr{acktags              = ChAckTags1,
                          unsent_message_count = Count + 1}),
    R.

record_ack(ChPid, LimiterPid, AckTag) ->
    C = #cr{acktags = ChAckTags} = ch_record(ChPid, LimiterPid),
    update_ch_record(C#cr{acktags = queue:in(AckTag, ChAckTags)}),
    ok.

subtract_acks(ChPid, AckTags) ->
    case lookup_ch(ChPid) of
        not_found ->
            not_found;
        C = #cr{acktags = ChAckTags} ->
            update_ch_record(
              C#cr{acktags = subtract_acks(AckTags, [], ChAckTags)}),
            ok
    end.

subtract_acks([], [], AckQ) ->
    AckQ;
subtract_acks([], Prefix, AckQ) ->
    queue:join(queue:from_list(lists:reverse(Prefix)), AckQ);
subtract_acks([T | TL] = AckTags, Prefix, AckQ) ->
    case queue:out(AckQ) of
        {{value,  T}, QTail} -> subtract_acks(TL,             Prefix, QTail);
        {{value, AT}, QTail} -> subtract_acks(AckTags, [AT | Prefix], QTail)
    end.

possibly_unblock(Update, ChPid, State) ->
    case lookup_ch(ChPid) of
        not_found -> unchanged;
        C         -> C1 = Update(C),
                     case is_ch_blocked(C) andalso not is_ch_blocked(C1) of
                         false -> update_ch_record(C1),
                                  unchanged;
                         true  -> unblock(C1, State)
                     end
    end.

unblock(C = #cr{blocked_consumers = BlockedQ, limiter = Limiter},
        State = #state{consumers = Consumers, use = Use}) ->
    case lists:partition(
           fun({_P, {_ChPid, #consumer{tag = CTag}}}) ->
                   rabbit_limiter:is_consumer_blocked(Limiter, CTag)
           end, priority_queue:to_list(BlockedQ)) of
        {_, []} ->
            update_ch_record(C),
            unchanged;
        {Blocked, Unblocked} ->
            BlockedQ1  = priority_queue:from_list(Blocked),
            UnblockedQ = priority_queue:from_list(Unblocked),
            update_ch_record(C#cr{blocked_consumers = BlockedQ1}),
            {unblocked,
             tags(Unblocked),
             State#state{consumers = priority_queue:join(Consumers, UnblockedQ),
                         use       = update_use(Use, active)}}
    end.

resume_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:resume(Limiter)}
    end.

notify_sent_fun(Credit) ->
    fun (C = #cr{unsent_message_count = Count}) ->
            C#cr{unsent_message_count = Count - Credit}
    end.

activate_limit_fun() ->
    fun (C = #cr{limiter = Limiter}) ->
            C#cr{limiter = rabbit_limiter:activate(Limiter)}
    end.

credit_fun(IsEmpty, Credit, Drain, CTag) ->
    fun (C = #cr{limiter = Limiter}) ->
            C1 = C#cr{limiter = rabbit_limiter:credit(
                                  Limiter, CTag, Credit, IsEmpty, Drain)},
            case Drain andalso IsEmpty of
                true  -> send_drained(C1);
                false -> C1
            end
    end.

utilisation(#state{use = {active, Since, Avg}}) ->
    use_avg(now_micros() - Since, 0, Avg);
utilisation(#state{use = {inactive, Since, Active, Avg}}) ->
    use_avg(Active, now_micros() - Since, Avg).

%%----------------------------------------------------------------------------

lookup_ch(ChPid) ->
    case get({ch, ChPid}) of
        undefined -> not_found;
        C         -> C
    end.

ch_record(ChPid, LimiterPid) ->
    Key = {ch, ChPid},
    case get(Key) of
        undefined -> MonitorRef = erlang:monitor(process, ChPid),
                     Limiter = rabbit_limiter:client(LimiterPid),
                     C = #cr{ch_pid               = ChPid,
                             monitor_ref          = MonitorRef,
                             acktags              = queue:new(),
                             consumer_count       = 0,
                             blocked_consumers    = priority_queue:new(),
                             limiter              = Limiter,
                             unsent_message_count = 0},
                     put(Key, C),
                     C;
        C = #cr{} -> C
    end.

update_ch_record(C = #cr{consumer_count       = ConsumerCount,
                         acktags              = ChAckTags,
                         unsent_message_count = UnsentMessageCount}) ->
    case {queue:is_empty(ChAckTags), ConsumerCount, UnsentMessageCount} of
        {true, 0, 0} -> ok = erase_ch_record(C);
        _            -> ok = store_ch_record(C)
    end,
    C.

store_ch_record(C = #cr{ch_pid = ChPid}) ->
    put({ch, ChPid}, C),
    ok.

erase_ch_record(#cr{ch_pid = ChPid, monitor_ref = MonitorRef}) ->
    erlang:demonitor(MonitorRef),
    erase({ch, ChPid}),
    ok.

all_ch_record() -> [C || {{ch, _}, C} <- get()].

block_consumer(C = #cr{blocked_consumers = Blocked}, QEntry) ->
    update_ch_record(C#cr{blocked_consumers = add_consumer(QEntry, Blocked)}).

is_ch_blocked(#cr{unsent_message_count = Count, limiter = Limiter}) ->
    Count >= ?UNSENT_MESSAGE_LIMIT orelse rabbit_limiter:is_suspended(Limiter).

send_drained(C = #cr{ch_pid = ChPid, limiter = Limiter}) ->
    case rabbit_limiter:drained(Limiter) of
        {[],         Limiter}  -> C;
        {CTagCredit, Limiter2} -> rabbit_channel:send_drained(
                                    ChPid, CTagCredit),
                                  C#cr{limiter = Limiter2}
    end.

tags(CList) -> [CTag || {_P, {_ChPid, #consumer{tag = CTag}}} <- CList].

add_consumer({ChPid, Consumer = #consumer{args = Args}}, Queue) ->
    Priority = case rabbit_misc:table_lookup(Args, <<"x-priority">>) of
                   {_, P} -> P;
                   _      -> 0
               end,
    priority_queue:in({ChPid, Consumer}, Priority, Queue).

remove_consumer(ChPid, ConsumerTag, Queue) ->
    priority_queue:filter(fun ({CP, #consumer{tag = CTag}}) ->
                                  (CP /= ChPid) or (CTag /= ConsumerTag)
                          end, Queue).

remove_consumers(ChPid, Queue) ->
    priority_queue:filter(fun ({CP, _Consumer}) when CP =:= ChPid -> false;
                              (_)                                 -> true
                          end, Queue).

update_use({inactive, _, _, _}   = CUInfo, inactive) ->
    CUInfo;
update_use({active,   _, _}      = CUInfo,   active) ->
    CUInfo;
update_use({active,   Since,         Avg}, inactive) ->
    Now = now_micros(),
    {inactive, Now, Now - Since, Avg};
update_use({inactive, Since, Active, Avg},   active) ->
    Now = now_micros(),
    {active, Now, use_avg(Active, Now - Since, Avg)}.

use_avg(Active, Inactive, Avg) ->
    Time = Inactive + Active,
    Ratio = Active / Time,
    Weight = erlang:min(1, Time / 1000000),
    case Avg of
        undefined -> Ratio;
        _         -> Ratio * Weight + Avg * (1 - Weight)
    end.

now_micros() -> timer:now_diff(now(), {0,0,0}).