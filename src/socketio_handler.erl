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

-record(state, {action, config, sid, heartbeat_tref, messages, pid, is_ws = false, is_direct_ws = false}).

init(Req, [Config]) ->
    Method = cowboy_req:method(Req),
    QS = maps:from_list(cowboy_req:parse_qs(Req)),
    case QS of
        #{<<"transport">> := <<"polling">>, <<"sid">> := Sid} when is_binary(Sid)->
            case {socketio_session:find(Sid), Method} of
                {{ok, Pid}, <<"GET">>} ->
                    case socketio_session:pull_no_wait(Pid, self()) of
                        session_in_use ->
                            Req1 = cowboy_req:reply(200, text_headers(Req), <<"1:6">>, Req),
                            error_logger:info_msg("qs=~p, res=session in use~n",[QS]),
                            {ok, Req1, #state{action = session_in_use, config = Config, sid = Sid}};
                        [] ->
                            error_logger:info_msg("qs=~p, res=long poll~n",[QS]),
                            TRef = erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                            {cowboy_loop, Req, #state{action = heartbeat, config = Config, sid = Sid, heartbeat_tref = TRef, pid = Pid}, hibernate};
                        Messages ->
                            Req1 = reply_messages(Req, Messages, Config, false),
                            error_logger:info_msg("qs=~p, res=get ok~n",[QS]),
                            {ok, Req1, #state{action = data, messages = Messages, config = Config, sid = Sid, pid = Pid}}
                    end;
                {{ok, Pid}, <<"POST">>} ->
                    Protocol = Config#config.protocol,
                    case cowboy_req:read_body(Req) of
                        {ok, Body, Req1} ->
                            error_logger:info_msg("qs=~p, method=put, body = ~p~n",[QS, Body]),
                            Messages = Protocol:decode_polling(Body),
                            socketio_session:recv(Pid, Messages),
                            Req2 = cowboy_req:reply(200, text_headers(Req), <<>>, Req1),
                            error_logger:info_msg("qs=~p, res=put ok, body = ~p~n",[QS, Body]),
                            {ok, Req2, #state{action = ok, config = Config, sid = Sid}};
                        {error, _} ->
                            Req1 = cowboy_req:reply(404, text_headers(Req), <<>>, Req),
                            error_logger:info_msg("qs=~p, res=put fail~n",[QS]),
                            {ok, Req1, #state{action = error, config = Config, sid = Sid}}
                    end;
                {_, <<"OPTIONS">>} ->
                    Req1 = cowboy_req:reply(200, text_headers(Req), <<>>, Req),
                    error_logger:info_msg("qs=~p, res=option~n",[QS]),
                    {ok, Req1, #state{action = not_found, sid = Sid, config = Config}};
                {{error, not_found}, _} ->
                    Req1 = cowboy_req:reply(404, text_headers(Req), <<>>, Req),
                    error_logger:info_msg("qs=~p, res=session not found~n",[QS]),
                    {ok, Req1, #state{action = not_found, sid = Sid, config = Config}};
                Other ->
                    Req1 = cowboy_req:reply(404, text_headers(Req), <<>>, Req),
                    error_logger:info_msg("qs=~p, res=unknown:~p~n",[QS, Other]),
                    {ok, Req1, #state{action = error, sid = Sid, config = Config}}
            end;

        #{<<"transport">> := <<"websocket">>, <<"sid">> := Sid} when is_binary(Sid) ->
            error_logger:info_msg("qs=~p, res=websocket ok~n",[QS]),
            {cowboy_websocket, Req, #state{config = Config, sid = Sid, is_ws = true}};
        #{<<"transport">> := <<"websocket">>}  ->
            error_logger:info_msg("qs=~p, res=websocket no sid, so create one~n",[QS]),
            #config{session_timeout = SessionTimeout,
                    opts = Opts,
                    callback = Callback} = Config,
            case is_map(Opts) of
                true ->
                    NewOpts = Opts#{req => Req};
                false ->
                    NewOpts = Opts
            end,
            Sid = socketio_session:create(SessionTimeout, Callback, NewOpts),
            {cowboy_websocket, Req, #state{config = Config, sid = Sid, is_ws = true, is_direct_ws = true}};
        #{<<"transport">> := <<"polling">>} ->
            #config{heartbeat_timeout = HeartbeatTimeout,
                    heartbeat = HeartbeatInterval,
                    session_timeout = SessionTimeout,
                    opts = Opts,
                    callback = Callback} = Config,
            case is_map(Opts) of
                true ->
                    NewOpts = Opts#{req => Req};
                false ->
                    NewOpts = Opts
            end,
            NewSid = socketio_session:create(SessionTimeout, Callback, NewOpts),

            Payload = iolist_to_binary(jsx:encode(#{sid=>NewSid,
                                                    upgrades=>[<<"websocket">>],
                                                    pingInterval=>HeartbeatInterval,
                                                    pingTimeout=>HeartbeatTimeout})),
            Result = <<(integer_to_binary(byte_size(Payload)+1))/binary,":0", Payload/binary, "2:40">>,
            Req01 = cowboy_req:set_resp_cookie(<<"io">>,NewSid,Req),
            Req1 = cowboy_req:reply(200, text_headers(Req), Result, Req01),
            error_logger:info_msg("qs=~p, res=create session ok~n",[QS]),
            {ok, Req1, #state{action = create_session, config = Config}};
        Other ->
            Req1 = cowboy_req:reply(404, text_headers(Req), <<>>, Req),
            error_logger:info_msg("qs=~p, res=unknown:~p~n",[QS, Other]),
            {ok, Req1, #state{config = Config}}
    end.

info({timeout, TRef, {?MODULE, Pid}}, Req, HttpState = #state{action = heartbeat, heartbeat_tref = TRef}) ->
    safe_poll(Req, HttpState#state{heartbeat_tref = undefined}, Pid, false);

info({message_arrived, Pid}, Req, HttpState = #state{action = heartbeat}) ->
    safe_poll(Req, HttpState, Pid, true);

info(kick_caller, Req, #state{config = Config}=HttpState) ->
    Req1 = reply_messages(Req, [nop], Config, true),
    {stop, Req1, HttpState};

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
    end;
terminate(_Reason, _Req, _HttpState) ->
    ok.

text_headers(Req) ->
    case application:get_env(socketio, access_control_allow_origin, all) of
        all ->
            Origin = case cowboy_req:header(<<"origin">>, Req) of
                         undefined -> <<"*">>;
                         Ori -> Ori
                     end;
        Origin when is_binary(Origin) ->
            ok
    end,
    #{<<"content-type">> => <<"text/plain; charset=utf-8">>,
      <<"cache-control">> => <<"no-cache">>,
      <<"expires">> => <<"Sat, 25 Dec 1999 00:00:00 GMT">>,
      <<"pragma">> => <<"no-cache">>,
      <<"access-control-allow-credentials">> => <<"true">>,
      <<"access-control-allow-origin">> => Origin,
      <<"Access-Control-Allow-Headers">> => <<"Origin, X-Requested-With, Content-Type, Accept">>,
      <<"Access-Control-Allow-Methods">> => <<"POST, GET, PUT, DELETE, OPTIONS">>}.

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop) ->
    NewMessages = case {SendNop, Messages} of
                      {true, []} ->
                          [nop];
                      _ ->
                          Messages
             end,
    Packet = Protocol:encode_polling(NewMessages),
    cowboy_req:reply(200, text_headers(Req), Packet, Req).

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
        exit:{{nodedown,_},_} -> error;
        exit:{normal, _} -> ok;
        C:E ->
            error_logger:info_msg("safe_unsub_caller unknown:~p~n",[{C,E}]),
            error
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
            error_logger:error_msg("poll fail, go to stop~n",[]),
            RD = cowboy_req:reply(200, text_headers(Req), Protocol:encode(disconnect), Req),
            {stop, RD, HttpState#state{action = disconnect}}
    end.

%% Websocket handlers
websocket_init(#state{sid = Sid, is_direct_ws = IsDirectWS} = State) ->
    case socketio_session:find(Sid) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            IsDirectWS andalso ( self() ! direct_ws ),
            self() ! go_and_kick,
            {ok, State#state{pid = Pid}};
        {error, not_found} ->
            {stop, State}
    end.

websocket_handle({text, Data}, #state{config = #config{protocol = Protocol}, pid = Pid} = State) ->
    Messages = Protocol:decode(Data),
    case Messages of
        [probe] ->
            socketio_session:recv(Pid, Messages),
            reply_ws_messages([probe], State);
        [upgrade] ->
            self() ! go,
            error_logger:info_msg("upgrade ok", []),
            socketio_session:recv(Pid, Messages),
            {ok, State};
        _ ->
            socketio_session:recv(Pid, Messages),
            {ok, State}
    end;
websocket_handle({binary, Data}, #state{config = #config{protocol = Protocol}, pid = Pid} = State) ->
    Messages = Protocol:decode(Data),
    socketio_session:recv(Pid, Messages),
    {ok, State};
websocket_handle(_Data, State) ->
    {ok, State}.


websocket_info(go_and_kick, #state{pid = Pid} = State) ->
    case socketio_session:pull_kick(Pid, self()) of
        session_in_use ->
            {ok, State};
        Messages ->
            reply_ws_messages(Messages, State)
    end;
websocket_info(go, #state{pid = Pid} = State) ->
    case socketio_session:pull(Pid, self()) of
        session_in_use ->
            {ok, State};
        Messages ->
            reply_ws_messages(Messages, State)
    end;
websocket_info(direct_ws, #state{sid = Sid, config = Config} = State) ->
    #config{heartbeat_timeout = HeartbeatTimeout,
                    heartbeat = HeartbeatInterval} = Config,
            EndPoint = iolist_to_binary(jsx:encode(#{sid=>Sid,
                                                    upgrades=>[],
                                                    pingInterval=>HeartbeatInterval,
                                                    pingTimeout=>HeartbeatTimeout})),
    ConnectMessage = {connect, EndPoint},
    OpenMessage = open,
    reply_ws_messages([ConnectMessage, OpenMessage], State);
websocket_info({message_arrived, Pid}, State) ->
    Messages =  socketio_session:poll(Pid),
    self() ! go,
    reply_ws_messages(Messages, State);
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, #state{pid = Pid} = State) ->
    {stop, State};
websocket_info(kick_caller, State) ->
    reply_ws_messages([nop], State),
    {stop, State};
websocket_info(_Info, State) ->
    {ok, State}.

reply_ws_messages(Messages, #state{config = #config{protocol = Protocol}} = State) ->
    Replys = lists:flatmap(
               fun(Message) ->
                       case Protocol:encode([Message]) of
                           [PlaceHolder, Binary] ->
                               [{text, PlaceHolder}, {binary, Binary}];
                           <<>> ->
                               [];
                           Text ->
                               [{text, Text}]
                       end
               end, Messages),
    case Replys of
        [] ->
            {ok, State};
        _ ->
            {reply, Replys, State}
    end.
