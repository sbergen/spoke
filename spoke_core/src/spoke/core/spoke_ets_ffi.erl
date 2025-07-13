-module(spoke_ets_ffi).

-export([new/0, read/1, update_next_id/2, load_from_file/1, store_to_file/2]).

load_from_file(Filename) ->
    ets:file2tab(
        unicode:characters_to_list(Filename)).

store_to_file(Table, Filename) ->
    case ets:tab2file(Table, unicode:characters_to_list(Filename)) of
        ok ->
            {ok, nil};
        Error ->
            Error
    end.

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
