-module(socketio_data_protocol_v3).
-compile([export_all, {no_auto_import, [error/2]}]).

%% The source code was taken and modified from socketio_data_protocol.erl

encode_polling([Message]) ->
    Data = encode([Message]),
    Size = byte_size(Data),
    <<(integer_to_binary(Size))/binary, ":", Data/binary>>;
encode_polling(Messages) ->
    iolist_to_binary(encode_polling_frames(Messages)).

encode_polling_frames(Messages) ->
    lists:flatmap(
      fun(Message) ->
              case encode([Message]) of
                  [PlaceHolder, Binary] ->
                      [encode_polling_frame(PlaceHolder, text),
                       encode_polling_frame(Binary, binary)];
                  Text ->
                      [encode_polling_frame(Text, text)]
              end
      end, Messages).

encode_polling_frame(Data, text) ->
    Size = byte_size(Data),
    <<(integer_to_binary(Size))/binary, ":", Data/binary>>;
encode_polling_frame(Data, binary) ->
    DataBase64 = base64:encode(Data),
    Size = byte_size(DataBase64),
    <<(integer_to_binary(Size+1))/binary, ":b", DataBase64/binary>>.

encode([Message]) ->
    encode(Message);
encode({message, Id, EndPoint, Message}) ->
    message(Id, EndPoint, Message);
encode({json, Id, EndPoint, Message}) ->
    json(Id, EndPoint, Message);
encode({connect, Endpoint}) ->
    connect(Endpoint);
encode(heartbeat) ->
    heartbeat();
encode(probe) ->
    probe();
encode(nop) ->
    nop();
encode(disconnect) ->
    disconnect(<<>>).

connect(<<>>) ->
    <<"0">>;
connect(Endpoint) ->
    <<"0", Endpoint/binary>>.

disconnect(<<>>) ->
    <<"1">>;
disconnect(Endpoint) ->
    <<"1", Endpoint/binary>>.

heartbeat() ->
    <<"3">>.

probe() ->
    <<"3probe">>.

nop() ->
    <<"6">>.

message(_Id, EndPoint, Msg) ->
    JsonBin = jsx:encode([EndPoint, #{'_placeholder'=>true, num=>0}]),
    PlaceHolder = <<"451-", JsonBin/binary>>,
    [PlaceHolder, <<4, Msg/binary>>].

json(_Id, EndPoint, Msg) ->
    JsonBin = jsx:encode([EndPoint, Msg]),
    <<"42", JsonBin/binary>>.

error(EndPoint, Reason) ->
    [<<"4">>, EndPoint, $:, Reason].
error(EndPoint, Reason, Advice) ->
    [<<"4">>, EndPoint, $:, Reason, $+, Advice].

decode_polling(<<0,_/binary>> = Bin) ->
    decode_polling_frames(Bin, []);
decode_polling(<<1,_/binary>> = Bin) ->
    decode_polling_frames(Bin, []);
decode_polling(Bin) ->
    case decode_polling(Bin, []) of
        [Packet] -> Packet;
        Frames -> Frames
    end.

decode_polling(<<>>, Acc) ->
    lists:reverse(Acc);
decode_polling(Bin, Acc) ->
    [LenBin, Rest] = binary:split(Bin, <<":">>),
    Len = binary_to_integer(LenBin),
    <<Data:Len/binary-unit:8, Rest2/binary>> = Rest,
    decode_polling(Rest2, [decode(Data)|Acc]).

decode_polling_frames(<<0, Rest/binary>>, Acc) -> %% string
    {Data,Rest2} = parse_polling(Rest),
    decode_polling_frames(Rest2, decode(Data) ++ Acc);
decode_polling_frames(<<1, Rest/binary>>, Acc) -> %% binary
    {Data,Rest2} = parse_polling(Rest),
    decode_polling_frames(Rest2, decode(Data) ++ Acc);
decode_polling_frames(<<>>, Acc) ->
    lists:reverse(Acc).

parse_polling(Bin) ->
    parse_polling(Bin, 0).

parse_polling(<<255,Rest/binary>>, Len) ->
    <<Data:Len/binary-unit:8, Rest2/binary>> = Rest,
    {Data, Rest2};
parse_polling(<<I, Rest/binary>>, Len) ->
    parse_polling(Rest, Len * 10 + I).

decode(Binary) ->
    [decode_packet(Binary)].

decode_packet(<<"0">>) -> connect;
decode_packet(<<"1">>) -> disconnect;
decode_packet(<<"2">>) -> heartbeat;
decode_packet(<<"2probe">>) -> probe;
decode_packet(<<"5">>) -> upgrade;
decode_packet(<<"42", Rest/binary>>) ->
    case jsx:decode(Rest, [return_maps]) of
        [Event,Data] ->
            {json, <<>>, Event, Data};
        [Event] ->
            {json, <<>>, Event, <<>>}
    end;
decode_packet(<<"45", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    case jsx:decode(R1, [return_maps]) of
        [Event, Data] ->
            {json, Id, Event, Data};
        [Event] ->
            {json, Id, Event, <<>>}
    end;
decode_packet(<<4, Rest/binary>>) ->
    {message, <<>>, <<>>, Rest};
decode_packet(<<"3:", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    {EndPoint, Data} = endpoint(R1),
    {message, Id, EndPoint, Data};
decode_packet(<<"5:", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    {EndPoint, Data} = endpoint(R1),
    {message, Id, EndPoint, Data};
decode_packet(<<"4:", Rest/binary>>) ->
    {Id, R1} = id(Rest),
    {EndPoint, Data} = endpoint(R1),
    {json, Id, EndPoint, jsx:decode(Data)};
decode_packet(<<"7::", Rest/binary>>) ->
    {EndPoint, R1} = endpoint(Rest),
    case reason(R1) of
        {Reason, Advice} ->
            {error, EndPoint, Reason, Advice};
        Reason ->
            {error, EndPoint, Reason}
    end.

id(X) ->
    case binary:split(X, <<"-">>) of
        [Id,Rest] ->
            {Id, Rest};
        [Rest] ->
            {<<>>, Rest}
    end.

endpoint(X) -> endpoint(X, "").
endpoint(<<$:, Rest/binary>>, Acc) -> {binary:list_to_bin(lists:reverse(Acc)), Rest};
endpoint(<<X, Rest/binary>>, Acc) -> endpoint(Rest, [X|Acc]).

reason(X) ->
    case list_to_tuple(binary:split(X, <<"+">>)) of
	{E} -> E;
	T -> T
    end.
