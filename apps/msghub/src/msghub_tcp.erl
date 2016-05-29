-module(msghub_tcp).
-author('manuel@altenwald.com').

-behaviour(gen_server).

-export([
    start/0,
    stop/1,
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-record(state, {
    socket :: port(),
    csocket :: port()
}).

%%====================================================================
%% API
%%====================================================================

start() ->
    case application:get_env(msghub, tcp, []) of
        [] ->
            lager:info("TCP disabled~n", []),
            [];
        #{ port := Port }=Cfg ->
            {ok, Socket} = gen_tcp:listen(Port, [
                binary, inet,
                {active, false},
                {reuseaddr, true},
                {packet, raw}
            ]),
            case maps:find(poolsize, Cfg) of
                {ok, Poolsize} -> ok;
                _ -> Poolsize = 10
            end,
            lists:map(fun(N) ->
                {
                    "msghub_tcp_" ++ integer_to_list(N),
                    {?MODULE, start_link, [Socket]},
                    permanent, brutal_kill, worker, [?MODULE]
                }
            end, lists:seq(1, Poolsize));
        _ ->
            lager:error("port not defined in TCP configuration!", []),
            throw({error, enoport})
    end.

stop(PID) ->
    gen_server:call(PID, stop).

start_link(Socket) ->
    gen_server:start_link(?MODULE, [Socket], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Socket]) ->
    gen_server:cast(self(), wait),
    {ok, #state{socket=Socket}}.

handle_call(stop, _From, #state{csocket=undefined}=State) ->
    {stop, normal, ok, State};
handle_call(stop, _From, #state{csocket=CSocket}=State) ->
    msghub:unsubscribe_all(CSocket),
    gen_tcp:close(CSocket),
    {stop, normal, ok, State#state{csocket=undefined}}.

handle_cast(wait, #state{socket=Socket}=State) ->
    case gen_tcp:accept(Socket, 200) of
        {ok, ClientSocket} ->
            lager:info("accepted ~p", [self()]),
            inet:setopts(ClientSocket, [{active,once}]),
            {noreply, State#state{csocket=ClientSocket}};
        {error, timeout} ->
            gen_server:cast(self(), wait),
            {noreply, State};
        _ ->
            {stop, normal, State}
    end.

handle_info({tcp_closed, Socket}, State) ->
    gen_server:cast(self(), wait),
    msghub:unsubscribe_all(Socket),
    {noreply, State};

handle_info({tcp, Socket, Info}, State) ->
    inet:setopts(Socket, [{active,once}]),
    case msghub_utils:binary_split(Info, <<" ">>) of
        [<<"PUBLISH">>,Chan|RawValues] ->
            Value = msghub_utils:binary_join(RawValues, <<" ">>),
            msghub:publish(Chan, Value),
            lager:info("publish [~p] => ~p", [Chan, Value]),
            gen_tcp:send(Socket, <<"OK\n">>),
            {noreply, State};
        [<<"SUBSCRIBE">>,Chan] ->
            msghub:subscribe(Chan, Socket),
            lager:info("subscribe [~p] => ~p", [Socket, Chan]),
            gen_tcp:send(Socket, <<"OK\n">>),
            {noreply, State};
        [<<"UNSUBSCRIBE">>,Chan] ->
            msghub:unsubscribe(Chan, Socket),
            lager:info("unsubscribed [~p] => ~p", [Socket, Chan]),
            gen_tcp:send(Socket, <<"OK\n">>),
            {noreply, State};
        [<<"QUIT">>|_] ->
            gen_server:cast(self(), wait),
            msghub:unsubscribe_all(Socket),
            gen_tcp:close(Socket),
            {noreply, State#state{csocket=undefined}};
        _Command ->
            lager:warning("unknown command: ~p", [_Command]),
            gen_tcp:send(Socket, <<"Unknown command\n">>),
            {noreply, State}
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _Socket) ->
    ok.

%%====================================================================
%% Test functions
%%====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 5555).

config_test() ->
    application:set_env(msghub, tcp, #{ port => ?PORT, poolsize => 2 }),
    Data = [{_,{_,_,[Socket]},_,_,_,_}|_] = msghub_tcp:start(),
    ?assertMatch(
        [{
            "msghub_tcp_1", {?MODULE, start_link, [Socket]},
            permanent, brutal_kill, worker, [?MODULE]
        },{
            "msghub_tcp_2", {?MODULE, start_link, [Socket]},
            permanent, brutal_kill, worker, [?MODULE]
        }],
        Data
    ),
    gen_tcp:close(Socket),
    ok.

config_default_test() ->
    application:set_env(msghub, tcp, #{ port => ?PORT }),
    Data = [{_,{_,_,[Socket]},_,_,_,_}|_] = msghub_tcp:start(),
    ?assertEqual(10, length(Data)),
    gen_tcp:close(Socket),
    ok.

config_disabled_test() ->
    application:set_env(msghub, tcp, []),
    ?assertEqual([], msghub_tcp:start()),
    ok.

config_exception_test() ->
    application:set_env(msghub, tcp, #{}),
    ?assertThrow({error, enoport}, msghub_tcp:start()),
    ok.

close_socket_test() ->
    application:set_env(msghub, tcp, #{ port => ?PORT, poolsize => 1 }),
    [{_,{_,_,[Socket]},_,_,_,_}|_] = msghub_tcp:start(),
    {ok, PID} = start_link(Socket),
    gen_tcp:close(Socket),
    timer:sleep(250),
    ?assertEqual(false, is_process_alive(PID)),
    timer:sleep(100),
    ok.

setup_test_() ->
    {foreach,
        fun() ->
            pg2:create(channels),
            application:set_env(msghub, tcp, #{ port => ?PORT, poolsize => 3 }),
            ConnData = msghub_tcp:start(),
            [{_,{_,_,[Socket]},_,_,_,_}|_] = ConnData,
            PIDs = lists:map(fun({_,{_,_,[S]},_,_,_,_}) ->
                {ok, PID} = msghub_tcp:start_link(S),
                PID
            end, ConnData),
            {PIDs,Socket}
        end,
        fun({PIDs,Socket}) ->
            lists:foreach(fun(PID) ->
                msghub_tcp:stop(PID)
            end, PIDs),
            gen_tcp:close(Socket),
            pg2:delete(channels),
            timer:sleep(250)
        end,
        [
            fun pub_and_sub/1,
            fun unsub/1,
            fun chat/1,
            fun groupchat/1,
            fun unknown_command/1,
            fun code_change/1,
            fun quit_command/1
        ]
    }.

connect() ->
    gen_tcp:connect({127,0,0,1}, ?PORT, [binary, {active, false}, {packet, line}]).

send(Socket, Msg) ->
    gen_tcp:send(Socket, Msg).

recv(Socket, Match) ->
    ?assertMatch({ok, Match}, gen_tcp:recv(Socket, 0, 250)).

recv_error(Socket, Error) ->
    ?assertMatch({error, Error}, gen_tcp:recv(Socket, 0, 250)).

pub_and_sub(_) ->
    ?_test(begin
        {ok, Socket} = connect(),
        send(Socket, <<"SUBSCRIBE chan1\n">>),
        recv(Socket, <<"OK\n">>),
        send(Socket, <<"PUBLISH chan1 hello\n">>),
        recv(Socket, <<"OK\n">>),
        recv(Socket, <<"hello\n">>),
        gen_tcp:close(Socket),
        ok
    end).

unsub(_) ->
    ?_test(begin
        {ok, Socket} = connect(),
        send(Socket, <<"SUBSCRIBE chan2\n">>),
        recv(Socket, <<"OK\n">>),
        send(Socket, <<"PUBLISH chan2 hello\n">>),
        recv(Socket, <<"OK\n">>),
        recv(Socket, <<"hello\n">>),
        send(Socket, <<"UNSUBSCRIBE chan2\n">>),
        recv(Socket, <<"OK\n">>),
        recv(Socket, <<"UNSUBSCRIBED chan2\n">>),
        send(Socket, <<"PUBLISH chan2 hello\n">>),
        recv(Socket, <<"OK\n">>),
        recv_error(Socket, timeout),
        gen_tcp:close(Socket),
        ok
    end).

groupchat(_) ->
    ?_test(begin
        {ok, Alice} = connect(),
        send(Alice, <<"SUBSCRIBE friends\n">>),
        recv(Alice, <<"OK\n">>),

        {ok, Bob} = connect(),
        send(Bob, <<"SUBSCRIBE friends\n">>),
        recv(Bob, <<"OK\n">>),

        send(Bob, <<"PUBLISH friends hi girl!\n">>),
        recv(Bob, <<"OK\n">>),
        recv(Bob, <<"hi girl!\n">>),
        recv(Alice, <<"hi girl!\n">>),

        send(Alice, <<"PUBLISH friends hello Bob!\n">>),
        recv(Alice, <<"OK\n">>),
        recv(Alice, <<"hello Bob!\n">>),
        recv(Bob, <<"hello Bob!\n">>),

        send(Alice, <<"UNSUBSCRIBE friends\n">>),
        recv(Alice, <<"OK\n">>),
        recv(Alice, <<"UNSUBSCRIBED friends\n">>),

        send(Bob, <<"UNSUBSCRIBE friends\n">>),
        recv(Bob, <<"OK\n">>),
        recv(Bob, <<"UNSUBSCRIBED friends\n">>),

        gen_tcp:close(Alice),
        gen_tcp:close(Bob),
        ok
    end).

chat(_) ->
    ?_test(begin
        {ok, Alice} = connect(),
        send(Alice, <<"SUBSCRIBE alice\n">>),
        recv(Alice, <<"OK\n">>),

        {ok, Bob} = connect(),
        send(Bob, <<"SUBSCRIBE bob\n">>),
        recv(Bob, <<"OK\n">>),

        send(Bob, <<"PUBLISH alice hi girl!\n">>),
        recv(Bob, <<"OK\n">>),
        recv(Alice, <<"hi girl!\n">>),

        send(Alice, <<"PUBLISH bob hello Bob!\n">>),
        recv(Alice, <<"OK\n">>),
        recv(Bob, <<"hello Bob!\n">>),

        send(Alice, <<"UNSUBSCRIBE alice\n">>),
        recv(Alice, <<"OK\n">>),
        recv(Alice, <<"UNSUBSCRIBED alice\n">>),

        send(Bob, <<"UNSUBSCRIBE bob\n">>),
        recv(Bob, <<"OK\n">>),
        recv(Bob, <<"UNSUBSCRIBED bob\n">>),

        gen_tcp:close(Alice),
        gen_tcp:close(Bob),
        ok
    end).

unknown_command(_) ->
    ?_test(begin
        {ok, Socket} = connect(),
        send(Socket, <<"HELLO\n">>),
        recv(Socket, <<"Unknown command\n">>),
        gen_tcp:close(Socket),
        ok
    end).

code_change({[PID|_],_}) ->
    ?_test(begin
        ok = sys:suspend(PID),
        ok = sys:change_code(PID, ?MODULE, "0", []),
        ok = sys:resume(PID)
    end).

quit_command(_) ->
    ?_test(begin
        {ok, Socket} = connect(),
        gen_tcp:send(Socket, <<"QUIT\n">>),
        timer:sleep(200),
        gen_tcp:close(Socket),
        ok
    end).

-endif.
