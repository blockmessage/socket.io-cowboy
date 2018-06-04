%% @author Kirill Trofimov <sinnus@gmail.com>
%% @copyright 2012 Kirill Trofimov
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(socketio_handler).
-author('Kirill Trofimov <sinnus@gmail.com>').
-include("socketio_internal.hrl").

-export([init/2, info/3, terminate/3,
         websocket_init/1, websocket_handle/2,
         websocket_info/2]).

-record(state, {action, config, sid, heartbeat_tref, messages, pid, is_ws = false}).

init(Req, [Config]) ->
    PathInfo = cowboy_req:path_info(Req),
    Method = cowboy_req:method(Req),
    case PathInfo of
        [] ->
            #config{heartbeat_timeout = HeartbeatTimeout,
                    session_timeout = SessionTimeout,
                    opts = Opts,
                    callback = Callback} = Config,
            HeartbeatTimeoutBin = list_to_binary(integer_to_list(HeartbeatTimeout div 1000)),
            SessionTimeoutBin = list_to_binary(integer_to_list(SessionTimeout div 1000)),

            Pid = socketio_session:create(SessionTimeout, Callback, Opts),

            Result = <<":", HeartbeatTimeoutBin/binary, ":", SessionTimeoutBin/binary, ":websocket,xhr-polling">>,
            Req1 = cowboy_req:reply(200, text_headers(), <<Pid/binary, Result/binary>>, Req),
            {ok, Req1, #state{action = create_session, config = Config}};
        [<<"xhr-polling">>, Sid] ->
            case {socketio_session:find(Sid), Method} of
                {{ok, Pid}, <<"GET">>} ->
                    case socketio_session:pull_no_wait(Pid, self()) of
                        session_in_use ->
                            Req1 = cowboy_req:reply(404, #{}, <<>>, Req),
                            {ok, Req1, #state{action = session_in_use, config = Config, sid = Sid}};
                        [] ->
                            TRef = erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                            {cowboy_loop, Req, #state{action = heartbeat, config = Config, sid = Sid, heartbeat_tref = TRef, pid = Pid}, hibernate};
                        Messages ->
                            Req1 = reply_messages(Req, Messages, Config, false),
                            {ok, Req1, #state{action = data, messages = Messages, config = Config, sid = Sid, pid = Pid}}
                    end;
                {{ok, Pid}, <<"POST">>} ->
                    Protocol = Config#config.protocol,
                    case cowboy_req:read_body(Req) of
                        {ok, Body, Req1} ->
                            Messages = Protocol:decode(Body),
                            socketio_session:recv(Pid, Messages),
                            Req2 = cowboy_req:reply(200, text_headers(), <<>>, Req1),
                            {ok, Req2, #state{action = ok, config = Config, sid = Sid}};
                        {error, _} ->
                            Req1 = cowboy_req:reply(404, #{}, <<>>, Req),
                            {ok, Req1, #state{action = error, config = Config, sid = Sid}}
                    end;
                {{error, not_found}, _} ->
                    Req1 = cowboy_req:reply(404, #{}, <<>>, Req),
                    {ok, Req1, #state{action = not_found, sid = Sid, config = Config}};
                _ ->
                    Req1 = cowboy_req:reply(404, #{}, <<>>, Req),
                    {ok, Req1, #state{action = error, sid = Sid, config = Config}}
            end;
        [<<"websocket">>, Sid] ->
            {cowboy_websocket, Req, #state{config = Config, sid = Sid, is_ws = true}};
        _ ->
            Req1 = cowboy_req:reply(404, #{}, <<>>, Req),
            {ok, Req1, #state{config = Config}}
    end.

info({timeout, TRef, {?MODULE, Pid}}, Req, HttpState = #state{action = heartbeat, heartbeat_tref = TRef}) ->
    safe_poll(Req, HttpState#state{heartbeat_tref = undefined}, Pid, false);

info({message_arrived, Pid}, Req, HttpState = #state{action = heartbeat}) ->
    safe_poll(Req, HttpState, Pid, true);

info(_Info, Req, HttpState) ->
    {ok, Req, HttpState}.

%% ws terminate
terminate(_Reason, undefined, #state{is_ws = true, pid = Pid}) ->
    socketio_session:disconnect(Pid),
    ok;
terminate(_Reason, _Req, _HttpState = #state{action = create_session}) ->
    ok;
terminate(_Reason, _Req, _HttpState = #state{action = session_in_use}) ->
    ok;
terminate(_Reason, _Req, _HttpState = #state{heartbeat_tref = HeartbeatTRef, pid = Pid}) ->
    safe_unsub_caller(Pid, self()),
    case HeartbeatTRef of
        undefined ->
            ok;
        _ ->
            erlang:cancel_timer(HeartbeatTRef)
    end.

text_headers() ->
    #{<<"content-type">> => <<"text/plain; charset=utf-8">>,
      <<"cache-control">> => <<"no-cache">>,
      <<"expires">> => <<"Sat, 25 Dec 1999 00:00:00 GMT">>,
      <<"pragma">> => <<"no-cache">>,
      <<"access-control-allow-credentials">> => <<"true">>,
      <<"access-control-allow-origin">> => <<"null">>}.

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop) ->
    Packet = case {SendNop, Messages} of
                 {true, []} ->
                     Protocol:encode([nop]);
                 _ ->
                     Protocol:encode(Messages)
             end,
    cowboy_req:reply(200, text_headers(), Packet, Req).

safe_unsub_caller(undefined, _Caller) ->
    ok;

safe_unsub_caller(_Pid, undefined) ->
    ok;

safe_unsub_caller(Pid, Caller) ->
    try
        socketio_session:unsub_caller(Pid, Caller),
        ok
    catch
        exit:{noproc, _} -> error;
        exit:{{nodedown,_},_} -> error
    end.

safe_poll(Req, HttpState = #state{config = Config = #config{protocol = Protocol}}, Pid, WaitIfEmpty) ->
    try
        Messages = socketio_session:poll(Pid),
        case {WaitIfEmpty, Messages} of
            {true, []} ->
                {cowboy_loop, Req, HttpState};
            _ ->
                Req1 = reply_messages(Req, Messages, Config, true),
                {stop, Req1, HttpState}
        end
    catch
        exit:{noproc, _} ->
            RD = cowboy_req:reply(200, text_headers(), Protocol:encode(disconnect), Req),
            {stop, RD, HttpState#state{action = disconnect}}
    end.

%% Websocket handlers
websocket_init(#state{sid = Sid, config = Config} = State) ->
    case socketio_session:find(Sid) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            self() ! go,
            erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
            {ok, State#state{pid = Pid}};
        {error, not_found} ->
            {stop, State}
    end.

websocket_handle({text, Data}, #state{config = #config{protocol = Protocol}, pid = Pid} = State) ->
    Messages = Protocol:decode(Data),
    socketio_session:recv(Pid, Messages),
    {ok, State};
websocket_handle(_Data, State) ->
    {ok, State}.

websocket_info(go, #state{pid = Pid} = State) ->
    case socketio_session:pull(Pid, self()) of
        session_in_use ->
            {ok, State};
        Messages ->
            reply_ws_messages(Messages, State)
    end;
websocket_info({message_arrived, Pid}, State) ->
    Messages =  socketio_session:poll(Pid),
    self() ! go,
    reply_ws_messages(Messages, State);
websocket_info({timeout, _TRef, {?MODULE, Pid}}, #state{config = #config{protocol = Protocol} = Config, pid = Pid} = State) ->
    socketio_session:refresh(Pid),
    erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
    Packet = Protocol:encode(heartbeat),
    {reply, {text, Packet}, State};
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, #state{pid = Pid} = State) ->
    {stop, State};
websocket_info(_Info, State) ->
    {ok, State}.

reply_ws_messages(Messages, #state{config = #config{protocol = Protocol}} = State) ->
    case Protocol:encode(Messages) of
        <<>> ->
            {ok, State};
        Packet ->
            {reply, {text, Packet}, State}
    end.
