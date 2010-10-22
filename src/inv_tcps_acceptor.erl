%% Copyright (c) 2010 Invectorate LLC. All rights reserved.
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

-module(inv_tcps_acceptor).

-behaviour(gen_server).

%% API
-export([start/1, start_link/4]).
-export([accept/1]).
 
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Constants
-define(TIMEOUT, 500).

%% ===================================================================
%% API functions
%% ===================================================================

start(Supervisor) ->
    supervisor:start_child(Supervisor, []).

start_link(Listener, Callback, AcceptFun, CloseFun) ->
    gen_server:start_link(?MODULE, [Listener, Callback, AcceptFun, CloseFun], []).

accept(Pid) ->
    gen_server:cast(Pid, accept).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([Listener, Callback, AcceptFun, CloseFun]) ->
    {ok, {Listener, Callback, AcceptFun, CloseFun}}.

handle_call(_Message, _From, State) ->
    {reply, ignore, State}.

handle_cast(accept, {Listener, Callback, AcceptFun, CloseFun} = State) ->
    case gen_tcp:accept(Listener, ?TIMEOUT) of
        {ok, Socket} ->
            try
                AcceptFun(self()),
                Callback(Socket)
            after
                gen_tcp:close(Socket),
                CloseFun(self())
            end,
            accept(self()),
            {noreply, State};
        {error, timeout} ->
            %% Allows us to process other messages in our mailbox
            accept(self()),
            {noreply, State};
        Error ->
            {stop, Error, State}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
