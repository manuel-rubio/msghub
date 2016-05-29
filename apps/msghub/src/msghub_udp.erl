-module(msghub_udp).
-author('manuel@altenwald.com').

-behaviour(gen_server).

-export([
    start/0,
    stop/0,
    start_link/1,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-record(udp, {socket, ip, port, message}).

%%====================================================================
%% API
%%====================================================================

start() ->
    case application:get_env(msghub, udp, []) of
        [] ->
            lager:info("UDP disabled~n", []),
            [];
        #{ port := Port } ->
            [{
                msghub_udp_sup, {?MODULE, start_link, [Port]},
                permanent, brutal_kill, worker, [?MODULE]
            }];
        _ ->
            lager:error("port not defined in UDP configuration!", []),
            throw({error, enoport})
    end.

stop() ->
    gen_server:cast(?MODULE, stop).

start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Port]) ->
    gen_udp:open(Port, [
        binary, inet,
        {active, once},
        {reuseaddr, true}
    ]).

handle_cast(stop, State) ->
    {stop, normal, State}.

handle_call(_Msg, _From, State) ->
    lager:warning("request unknown (~p): ~p~n", [_From, _Msg]),
    {reply, ok, State}.

handle_info(#udp{ip=IP, port=Port, message=Info, socket=Socket}, Socket) ->
    case msghub_utils:binary_split(Info, <<" ">>) of
        [<<"PUBLISH">>,Chan|RawValues] ->
            Value = msghub_utils:binary_join(RawValues, <<" ">>),
            msghub:publish(Chan, Value),
            lager:info("publish [~p] => ~p", [Chan, Value]),
            gen_udp:send(Socket, IP, Port, <<"OK\n">>);
        [<<"SUBSCRIBE">>,Chan] ->
            msghub:subscribe(Chan, {Socket, IP, Port}),
            lager:info("subscribe [~p] => ~p", [{IP, Port}, Chan]),
            gen_udp:send(Socket, IP, Port, <<"OK\n">>);
        [<<"UNSUBSCRIBE">>,Chan] ->
            msghub:unsubscribe(Chan, {Socket, IP, Port}),
            lager:info("unsubscribed [~p] => ~p", [Socket, Chan]),
            gen_udp:send(Socket, IP, Port, <<"OK\n">>);
        _Command ->
            lager:warning("unknown command: ~p", [_Command]),
            gen_udp:send(Socket, IP, Port, <<"Unknown command\n">>)
    end,
    inet:setopts(Socket, [{active,once}]),
    {noreply, Socket}.

code_change(_OldVsn, State, _Extra) ->
    lager:info("code changed!"),
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Test functions
%%====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 5555).

config_test() ->
    application:set_env(msghub, udp, #{ port => ?PORT }),
    ?assertEqual(
        [{
            msghub_udp_sup, {?MODULE, start_link, [?PORT]},
            permanent, brutal_kill, worker, [?MODULE]
        }],
        msghub_udp:start()
    ),
    ok.

config_disabled_test() ->
    application:set_env(msghub, udp, []),
    ?assertEqual([], msghub_udp:start()),
    ok.

config_exception_test() ->
    application:set_env(msghub, udp, #{}),
    ?assertThrow({error, enoport}, msghub_udp:start()),
    ok.

setup_test_() ->
    {foreach,
        fun() ->
            start_link(?PORT),
            ok
        end,
        fun(_) ->
            stop(),
            timer:sleep(250)
        end,
        [
            fun pub_and_sub/1,
            fun unsub/1,
            fun unknown_command/1,
            fun sending_call/1,
            fun code_change/1
        ]
    }.

connect() ->
    gen_udp:open(0, [binary, {active, false}]).

send(Socket, Msg) ->
    gen_udp:send(Socket, {127,0,0,1}, ?PORT, Msg).

recv(Socket, Match) ->
    ?assertMatch({ok, {_,_,Match}}, gen_udp:recv(Socket, 1024, 250)).

recv_error(Socket, Error) ->
    ?assertEqual({error, Error}, gen_udp:recv(Socket, 1024, 250)).

pub_and_sub(_) ->
    ?_test(begin
        {ok, Socket} = connect(),
        send(Socket, <<"SUBSCRIBE chan1\n">>),
        recv(Socket, <<"OK\n">>),
        send(Socket, <<"PUBLISH chan1 hello\n">>),
        recv(Socket, <<"OK\n">>),
        recv(Socket, <<"hello\n">>),
        gen_udp:close(Socket),
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
        gen_udp:close(Socket),
        ok
    end).

unknown_command(_) ->
    ?_test(begin
        {ok, Socket} = connect(),
        send(Socket, <<"HELLO\n">>),
        recv(Socket, <<"Unknown command\n">>),
        gen_udp:close(Socket),
        ok
    end).

sending_call(_) ->
    ?_assertEqual(ok, gen_server:call(?MODULE, whatever)).

code_change(_) ->
    ?_test(begin
        ok = sys:suspend(?MODULE),
        ok = sys:change_code(?MODULE, ?MODULE, "0", []),
        ok = sys:resume(?MODULE)
    end).

-endif.
