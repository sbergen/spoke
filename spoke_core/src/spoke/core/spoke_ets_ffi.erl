-module(spoke_ets_ffi).

-export([new/0, read/1, update_next_id/2]).

new() ->
    ets:new(spoke_mqtt_session, [public, set]).

update_next_id(Table, Id) ->
    ets:insert(Table, {next_id, Id}).

read(Table) ->
    AllEntries = ets:tab2list(Table),
    to_session_state(1, [], AllEntries).

to_session_state(NextId, PacketStates, []) ->
    {session_state, NextId, PacketStates};
to_session_state(NextId, PacketStates, [Entry | Rest]) ->
    case Entry of
        {next_id, NewNextId} ->
            to_session_state(NewNextId, PacketStates, Rest);
        {Id, State} ->
            to_session_state(NextId, [{Id, State} | PacketStates], Rest)
    end.
