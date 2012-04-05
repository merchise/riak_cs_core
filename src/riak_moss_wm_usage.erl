%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

%% @doc Webmachine resource for serving usage stats.
%%
%% `GET /usage/USER_KEY?s=STARTTIME&e=ENDTIME&a=ACCESS&b=STORAGE'
%%
%% `s3cmd get s3://usage/USER_KEY/ab/STARTTIME/ENDTIME'
%%
%% Default `s' is the beginning of the previous period.  If no `e' is
%% given, the return only includes data for the period containing `s'.
%%
%% The `a' and `b' parameters default to `false'. Set `a' to `true' to
%% get access usage stats.  Set `b' to `true' to get storage usage
%% stats.  Including each in the s3cmd enables that stat, excluding it
%% disables it.
%%
%% The `s3cmd' variant also supports `x' and `j' in the path segment
%% with the `a' and `b'.  Including `x' gets the results in XML
%% format; `j' gets them in JSON.  Default is JSON.
%%
%% This service is only available if a connection to Riak can be made.
%%
%% This resource only exists if the user named by the key exists.
%%
%% Authorization is done the same way as all other authorized
%% resources: with the `Authorization' header, hashed with S3 keys,
%% etc.
%%
%% JSON response looks like:
%% ```
%% {"Access":[{"Node":"riak_moss@127.0.0.1",
%%             "Samples":[{"StartTime":"20120113T194510Z",
%%                         "EndTime":"20120113T194520Z",
%%                         "KeyRead":{"Count":1,
%%                                    "BytesOut":22},
%%                         "KeyWrite":{"Count":2,
%%                                     "BytesIn":44},
%%                        {"StartTime":"20120113T194520Z",
%%                         "EndTime":"20120113T194530Z",
%%                         "KeyRead":{"Count":3,
%%                                    "BytesOut":66},
%%                         "KeyWrite":{"Count":4,
%%                                     "BytesIn":88}
%%                       ]}
%%           ],
%%  "Storage":"not_requested"}
%% '''
%%
%% XML response looks like:
%% ```
%% <?xml version="1.0" encoding="UTF-8"?>
%%   <Usage>
%%     <Access>
%%       <Node name="riak_moss@127.0.0.1">
%%         <Sample StartTime="20120113T194510Z" EndTime="20120113T194520Z">
%%           <Operation type="KeyRead">
%%             <Count>1</Count>
%%             <BytesOut>22</BytesOut>
%%           </Operation>
%%           <Operation type="KeyWrite">
%%             <Count>2</Count>
%%             <BytesIn>44</BytesIn>
%%           </Operation>
%%         </Sample>
%%         <Sample StartTime="20120113T194520Z" EndTime="20120113T194530Z">
%%           <Operation type="KeyRead">
%%             <Count>3</Count>
%%             <BytesOut>66</BytesOut>
%%           </Operation>
%%           <Operation type="KeyWrite">
%%             <Count>4</Count>
%%             <BytesIn>88</BytesIn>
%%           </Operation>
%%         </Sample>
%%       </Node>
%%     </Access>
%%   <Storage>not_requested</Storage>
%% </Usage>
%% '''
-module(riak_moss_wm_usage).

-export([
         init/1,
         service_available/2,
         malformed_request/2,
         resource_exists/2,
         content_types_provided/2,
         generate_etag/2,
         forbidden/2,
         produce_json/2,
         produce_xml/2,
         finish_request/2
        ]).

-ifdef(TEST).
-ifdef(EQC).
-compile([export_all]).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("webmachine/include/webmachine.hrl").
-include("rts.hrl").
-include("riak_moss.hrl").

-define(JSON_TYPE, "application/json").
-define(XML_TYPE, "application/xml").

%% Keys used in output - defined here to help keep JSON and XML output
%% as similar as possible.
-define(KEY_USAGE, 'Usage').
-define(KEY_ACCESS, 'Access').
-define(KEY_STORAGE, 'Storage').
-define(KEY_NODE, 'Node').
-define(KEY_SAMPLE,  'Sample').
-define(KEY_SAMPLES, 'Samples').
-define(KEY_OPERATION, 'Operation').
-define(KEY_TYPE, 'type').
-define(KEY_BUCKET, 'Bucket').
-define(KEY_NAME, 'name').
-define(KEY_ERROR, 'Error').
-define(KEY_ERRORS, 'Errors').
-define(KEY_REASON, 'Reason').
-define(KEY_MESSAGE, 'Message').

-record(ctx, {
          auth_bypass :: boolean(),
          riak :: pid(),
          user :: riak_moss:moss_user(),
          start_time :: calendar:datetime(),
          end_time :: calendar:datetime(),
          body :: iolist(),
          etag :: iolist()
         }).

init(Config) ->
    %% Check if authentication is disabled and
    %% set that in the context.
    AuthBypass = proplists:get_value(auth_bypass, Config),
    {ok, #ctx{auth_bypass=AuthBypass}}.

service_available(RD, Ctx) ->
    case riak_moss_utils:riak_connection() of
        {ok, Riak} ->
            {true, RD, Ctx#ctx{riak=Riak}};
        {error, _} ->
            {false, error_msg(RD, <<"Usage database connection failed">>), Ctx}
    end.

malformed_request(RD, Ctx) ->
    case parse_start_time(RD) of
        {ok, Start} ->
            case parse_end_time(RD, Start) of
                {ok, End} ->
                    case too_many_periods(Start, End) of
                        true ->
                            {true,
                             error_msg(RD, <<"Too much time requested">>),
                             Ctx};
                        false ->
                            {false, RD,
                             Ctx#ctx{start_time=lists:min([Start, End]),
                                     end_time=lists:max([Start, End])}}
                    end;
                error ->
                    {true, error_msg(RD, <<"Invalid end-time format">>), Ctx}
            end;
        error ->
            {true, error_msg(RD, <<"Invalid start-time format">>), Ctx}
    end.

resource_exists(RD, #ctx{riak=Riak}=Ctx) ->
    case riak_moss_utils:get_user(user_key(RD), Riak) of
        {ok, {User, _UserVclock}} ->
            {true, RD, Ctx#ctx{user=User}};
        {error, _} ->
            {false, error_msg(RD, <<"Unknown user">>), Ctx}
    end.

content_types_provided(RD, Ctx) ->
    Types = case {true_param(RD, "j"), true_param(RD, "x")} of
                {true,_} -> [{?JSON_TYPE, produce_json}];
                {_,true} -> [{?XML_TYPE, produce_xml}];
                {_,_} -> [{?JSON_TYPE, produce_json},
                          {?XML_TYPE, produce_xml}]
            end,
    {Types, RD, Ctx}.

generate_etag(RD, #ctx{etag=undefined}=Ctx) ->
    case content_types_provided(RD, Ctx) of
        {[{_Type, Producer}], _, _} -> ok;
        {Choices, _, _} ->
            Accept = wrq:get_req_header("Accept", RD),
            ChosenType = webmachine_util:choose_media_type(
                           [ Type || {Type, _} <- Choices ],
                           Accept),
            case [ P || {T, P} <- Choices, T == ChosenType ] of
                [] -> Producer = element(2, hd(Choices));
                [Producer|_] -> ok
            end
    end,
    {Body, NewRD, NewCtx} = ?MODULE:Producer(RD, Ctx),
    Etag = riak_moss_utils:binary_to_hexlist(crypto:md5(Body)),
    {Etag, NewRD, NewCtx#ctx{etag=Etag}};
generate_etag(RD, #ctx{etag=Etag}=Ctx) ->
    {Etag, RD, Ctx}.

forbidden(RD, #ctx{auth_bypass=AuthBypass, riak=Riak}=Ctx) ->
    BogusContext = #context{auth_bypass=AuthBypass, riakc_pid=Riak},
    Next = fun(NewRD, #context{user=User}) ->
                   forbidden(NewRD, Ctx, User)
           end,
    riak_moss_wm_utils:find_and_auth_user(RD, BogusContext, Next).

forbidden(RD, Ctx, undefined) ->
    %% anonymous access disallowed
    riak_moss_wm_utils:deny_access(RD, Ctx);
forbidden(RD, Ctx, User) ->
    case user_key(RD) == User?MOSS_USER.key_id of
        true ->
            %% user is accessing own stats
            AccessRD = riak_moss_access_logger:set_user(User, RD),
            {false, AccessRD, Ctx};
        false ->
            case riak_moss_utils:get_admin_creds() of
                {ok, {Admin, _}} when Admin == User?MOSS_USER.key_id ->
                    %% admin can access anyone's stats
                    {false, RD, Ctx};
                _ ->
                    %% no one else is allowed
                    riak_moss_wm_utils:deny_access(RD, Ctx)
            end
    end.

finish_request(RD, #ctx{riak=undefined}=Ctx) ->
    {true, RD, Ctx};
finish_request(RD, #ctx{riak=Riak}=Ctx) ->
    riak_moss_utils:close_riak_connection(Riak),
    {true, RD, Ctx#ctx{riak=undefined}}.

%% JSON Production %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
produce_json(RD, #ctx{body=undefined}=Ctx) ->
    Access = maybe_access(RD, Ctx),
    Storage = maybe_storage(RD, Ctx),
    MJ = {struct, [{?KEY_ACCESS, mochijson_access(Access)},
                   {?KEY_STORAGE, mochijson_storage(Storage)}]},
    Body = mochijson2:encode(MJ),
    {Body, RD, Ctx#ctx{body=Body}};
produce_json(RD, #ctx{body=Body}=Ctx) ->
    {Body, RD, Ctx}.

mochijson_access(Msg) when is_atom(Msg) ->
    Msg;
mochijson_access({Access, Errors}) ->
    orddict:fold(
      fun(Node, Samples, Acc) ->
              [{struct, [{?KEY_NODE, Node},
                         {?KEY_SAMPLES, [{struct, S} || S <- Samples]}]}
               |Acc]
      end,
      [{struct, [{?KEY_ERRORS, [ {struct, mochijson_sample_error(E)}
                                 || E <- Errors ]}]}],
      Access).

mochijson_sample_error({{Start, End}, Reason}) ->
    [{?START_TIME, rts:iso8601(Start)},
     {?END_TIME, rts:iso8601(End)},
     {?KEY_REASON, mochijson_reason(Reason)}].

mochijson_reason(Reason) ->
    if is_atom(Reason) -> atom_to_binary(Reason, latin1);
       is_binary(Reason) -> Reason;
       true -> list_to_binary(io_lib:format("~p", [Reason]))
    end.

mochijson_storage(Msg) when is_atom(Msg) ->
    Msg;
mochijson_storage({Storage, Errors}) ->
    [ mochijson_storage_sample(S) || S <- Storage ]
        ++ [{struct, [{?KEY_ERRORS, [mochijson_sample_error(E)
                                     || E <- Errors]}]}].

mochijson_storage_sample(Sample) ->
    {struct, Sample}.

%% XML Production %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
produce_xml(RD, #ctx{body=undefined}=Ctx) ->
    Access = maybe_access(RD, Ctx),
    Storage = maybe_storage(RD, Ctx),
    Doc = [{?KEY_USAGE, [{?KEY_ACCESS, xml_access(Access)},
                         {?KEY_STORAGE, xml_storage(Storage)}]}],
    Body = riak_moss_s3_response:export_xml(Doc),
    {Body, RD, Ctx#ctx{body=Body}};
produce_xml(RD, #ctx{body=Body}=Ctx) ->
    {Body, RD, Ctx}.

xml_access(Msg) when is_atom(Msg) ->
    [atom_to_list(Msg)];
xml_access({Access, Errors}) ->
    orddict:fold(
      fun(Node, Samples, Acc) ->
              [{?KEY_NODE, [{name, Node}],
                [xml_sample(S, ?KEY_OPERATION, ?KEY_TYPE) || S <- Samples]}
               |Acc]
      end,
      [{?KEY_ERRORS, [ xml_sample_error(E, ?KEY_OPERATION, ?KEY_TYPE)
                       || E <- Errors ]}],
      Access).

xml_sample(Sample, SubType, TypeLabel) ->
    {value, {?START_TIME,S}, SampleS} =
        lists:keytake(?START_TIME, 1, Sample),
    {value, {?END_TIME,E}, Rest} =
        lists:keytake(?END_TIME, 1, SampleS),

    {?KEY_SAMPLE, [{xml_name(?START_TIME), S}, {xml_name(?END_TIME), E}],
     [{SubType, [{TypeLabel, OpName}],
       [{xml_name(K), [mochinum:digits(V)]} || {K, V} <- Stats]}
      || {OpName, {struct, Stats}} <- Rest ]}.

xml_sample_error({{Start, End}, Reason}, SubType, TypeLabel) ->
    %% cheat to make errors structured exactly like samples
    FakeSample = [{?START_TIME, rts:iso8601(Start)},
                  {?END_TIME, rts:iso8601(End)}],
    {Tag, Props, Contents} = xml_sample(FakeSample, SubType, TypeLabel),

    XMLReason = xml_reason(Reason),
    {Tag, Props, [{?KEY_REASON, [XMLReason]}|Contents]}.

%% @doc JSON deserializes with keys as binaries, but xmerl requires
%% tag names to be atoms.
xml_name(Other) -> binary_to_atom(Other, latin1).

xml_reason(Reason) ->
    [if is_atom(Reason) -> atom_to_binary(Reason, latin1);
       is_binary(Reason) -> Reason;
       true -> io_lib:format("~p", [Reason])
     end].

xml_storage(Msg) when is_atom(Msg) ->
    [atom_to_list(Msg)];
xml_storage({Storage, Errors}) ->
    [xml_sample(S, ?KEY_BUCKET, ?KEY_NAME) || S <- Storage]
        ++ [{?KEY_ERRORS, [xml_sample_error(E, ?KEY_BUCKET, ?KEY_NAME)
                           || E <- Errors ]}].
    
%% Internals %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
user_key(RD) ->
    case path_tokens(RD) of
        [KeyId|_] -> mochiweb_util:unquote(KeyId);
        _         -> []
    end.

maybe_access(RD, Ctx) ->
    usage_if(RD, Ctx, "a", riak_moss_access).

maybe_storage(RD, Ctx) ->
    usage_if(RD, Ctx, "b", riak_moss_storage).

usage_if(RD, #ctx{riak=Riak, start_time=Start, end_time=End},
         QParam, Module) ->
    case true_param(RD, QParam) of
        true ->
            Module:get_usage(Riak, user_key(RD), Start, End);
        false ->
            not_requested
    end.

true_param(RD, Param) ->
    case lists:member(wrq:get_qs_value(Param, RD),
                      ["","t","true","1","y","yes"]) of
        true ->
            true;
        false ->
            case path_tokens(RD) of
                [_,Options|_] ->
                    0 < string:str(Options, Param);
                _ ->
                    false
            end
    end.

%% @doc Support both `/usage/Key/Opts/Start/End' and
%% `/usage/Key.Opts.Start.End', since some commands assume that you
%% want extra slashes quoted.
path_tokens(RD) ->
    case wrq:path_tokens(RD) of
        [JustOne] ->
            case string:chr(JustOne, $.) of
                0 ->
                    [JustOne];
                _ ->
                    %% URL is dot-separated options
                    string:tokens(JustOne, ".")
            end;
        Many ->
            Many
    end.

parse_start_time(RD) ->
    time_param(RD, "s", 3, calendar:universal_time()).

parse_end_time(RD, StartTime) ->
    time_param(RD, "e", 4, StartTime).

time_param(RD, Param, N, Default) ->
    case wrq:get_qs_value(Param, RD) of
        undefined ->
            case catch lists:nth(N, path_tokens(RD)) of
                {'EXIT', _} ->
                    {ok, Default};
                TimeString ->
                    datetime(TimeString)
            end;
        TimeString ->
            datetime(TimeString)
    end.

error_msg(RD, Message) ->
    {CTP, _, _} = content_types_provided(RD, #ctx{}),
    PTypes = [Type || {Type,_Fun} <- CTP],
    AcceptHdr = wrq:get_req_header("accept", RD),
    case webmachine_util:choose_media_type(PTypes, AcceptHdr) of
        ?JSON_TYPE=Type ->
            Body = json_error_msg(Message);
        _ ->
            Type = ?XML_TYPE,
            Body = xml_error_msg(Message)
    end,
    wrq:set_resp_header("content-type", Type, wrq:set_resp_body(Body, RD)).

json_error_msg(Message) when is_list(Message) ->
    json_error_msg(list_to_binary(Message));
json_error_msg(Message) ->
    MJ = {struct, [{?KEY_ERROR, {struct, [{?KEY_MESSAGE, Message}]}}]},
    mochijson2:encode(MJ).

xml_error_msg(Message) when is_binary(Message) ->
    xml_error_msg(binary_to_list(Message));
xml_error_msg(Message) ->
    Doc = [{?KEY_ERROR, [{?KEY_MESSAGE, [Message]}]}],
    riak_moss_s3_response:export_xml(Doc).

%% @doc Produce a datetime tuple from a ISO8601 string
-spec datetime(binary()|string()) -> {ok, calendar:datetime()} | error.
datetime(Binary) when is_binary(Binary) ->
    datetime(binary_to_list(Binary));
datetime(String) when is_list(String) ->
    case catch io_lib:fread("~4d~2d~2dT~2d~2d~2dZ", String) of
        {ok, [Y,M,D,H,I,S], _} ->
            {ok, {{Y,M,D},{H,I,S}}};
        %% TODO: match {more, _, _, RevList} to allow for shortened
        %% month-month/etc.
        _ ->
            error
    end.

%% @doc Will this request require more reads than the configured limit?
-spec too_many_periods(calendar:datetime(), calendar:datetime())
          -> boolean().
too_many_periods(Start, End) ->
    Seconds = calendar:datetime_to_gregorian_seconds(End)
        -calendar:datetime_to_gregorian_seconds(Start),
    {ok, Limit} = application:get_env(riak_moss, usage_request_limit),
    
    {ok, Access} = riak_moss_access:archive_period(),
    {ok, Storage} = riak_moss_storage:archive_period(),
    
    ((Seconds div Access) > Limit) orelse ((Seconds div Storage) > Limit).

-ifdef(TEST).
-ifdef(EQC).


datetime_test() ->
    true = eqc:quickcheck(datetime_invalid_prop()).

%% make sure that datetime correctly returns 'error' for invalid
%% iso8601 date strings
datetime_invalid_prop() ->
    ?FORALL(L, list(char()),
            case datetime(L) of
                {{_,_,_},{_,_,_}} ->
                    %% really, we never expect this to happen, given
                    %% that a random string is highly unlikely to be
                    %% valid iso8601, but just in case...
                    valid_iso8601(L);
                error ->
                    not valid_iso8601(L)
            end).

%% a string is considered valid iso8601 if it is of the form
%% ddddddddZddddddT, where d is a digit, Z is a 'Z' and T is a 'T'
valid_iso8601(L) ->
    length(L) == 4+2+2+1+2+2+2+1 andalso
        string:chr(L, $Z) == 4+2+2+1 andalso
        lists:all(fun is_digit/1, string:substr(L, 1, 8)) andalso
        string:chr(L, $T) == 16 andalso
        lists:all(fun is_digit/1, string:substr(L, 10, 15)).

is_digit(C) ->
    C >= $0 andalso C =< $9.

-endif. % EQC
-endif. % TEST
