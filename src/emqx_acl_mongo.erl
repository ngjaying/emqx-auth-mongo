%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_acl_mongo).

-behaviour(emqx_acl_mod).

-include("emqx_auth_mongo.hrl").
-include_lib("emqx/include/emqx.hrl").

%% ACL callbacks
-export([init/1, check_acl/2, reload_acl/1, description/0]).

init(AclQuery) ->
    {ok, #{aclquery => AclQuery}}.

check_acl({#{username := <<$$, _/binary>>}, _PubSub, _Topic}, _State) ->
    ignore;

check_acl({Credentials, PubSub, Topic}, #{aclquery := AclQuery}) ->
    #aclquery{collection = Coll, selector = SelectorList} = AclQuery,
    SelectorMapList =
        lists:map(fun(Selector) ->
            maps:from_list(emqx_auth_mongo:replvars(Selector, Credentials))
        end, SelectorList),
    case emqx_auth_mongo:query_multi(Coll, SelectorMapList) of
        [] -> ignore;
        Rows ->
            try match(Credentials, Topic, topics(PubSub, Rows)) of
                matched -> allow;
                nomatch -> deny
            catch
                Err:Reason->
                    lager:error("Check mongo (~p) ACL failed, got ACL config: ~p, error: {~p:~p}",
                                [PubSub, Rows, Err, Reason]),
                    ignore
            end
    end.

match(_Credentials, _Topic, []) ->
    nomatch;
match(Credentials, Topic, [TopicFilter|More]) ->
    case emqx_topic:match(Topic, feedvar(Credentials, TopicFilter)) of
        true  -> matched;
        false -> match(Credentials, Topic, More)
    end.

topics(publish, Rows) ->
    lists:foldl(fun(Row, Acc) ->
        Topics = maps:get(<<"publish">>, Row, []) ++ maps:get(<<"pubsub">>, Row, []),
        lists:umerge(Acc, Topics)
    end, [], Rows);

topics(subscribe, Rows) ->
    lists:foldl(fun(Row, Acc) ->
        Topics = maps:get(<<"subscribe">>, Row, []) ++ maps:get(<<"pubsub">>, Row, []),
        lists:umerge(Acc, Topics)
    end, [], Rows).

feedvar(#{client_id := ClientId, username := Username}, Str) ->
    lists:foldl(fun({Var, Val}, Acc) ->
                    feedvar(Acc, Var, Val)
                end, Str, [{"%u", Username}, {"%c", ClientId}]).

feedvar(Str, _Var, undefined) ->
    Str;
feedvar(Str, Var, Val) ->
    re:replace(Str, Var, Val, [global, {return, binary}]).

reload_acl(_State) ->
    ok.

description() -> "ACL with MongoDB".

