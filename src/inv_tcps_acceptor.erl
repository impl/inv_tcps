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
-export([start/1, start_link/5]).
-export([accept/1]).
 
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Constants
-define(TIMEOUT, 500).

%% State
-record(state, {listener, callback,
                accept_limit, accepts = 0,
                accept_fun, close_fun}).

%% ===================================================================
%% API functions
%% ===================================================================

start(Supervisor) ->
    supervisor:start_child(Supervisor, []).

start_link(Listener, Callback, AcceptLimit, AcceptFun, CloseFun) ->
    gen_server:start_link(?MODULE, [Listener, Callback, AcceptLimit, AcceptFun, CloseFun], []).

accept(Pid) ->
    gen_server:cast(Pid, accept).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([Listener, Callback, AcceptLimit, AcceptFun, CloseFun]) ->
    {ok, #state{listener = Listener, callback = Callback,
                accept_limit = AcceptLimit,
                accept_fun = AcceptFun, close_fun = CloseFun}}.

handle_call(_Message, _From, State) ->
    {reply, ignore, State}.

handle_cast(accept, #state{accept_limit = AcceptLimit, accepts = Accepts} = State) when is_integer(AcceptLimit) andalso
                                                                                        Accepts >= AcceptLimit ->
    {stop, normal, State};
handle_cast(accept, #state{listener = Listener, callback = Callback,
                           accepts = Accepts, accept_fun = AcceptFun, close_fun = CloseFun} = State) ->
    case gen_tcp:accept(Listener, ?TIMEOUT) of
        {ok, Socket} ->
            try
                AcceptFun(self()),
                callback(Callback, Socket)
            after
                gen_tcp:close(Socket),
                CloseFun(self())
            end,
            accept(self()),
            {noreply, State#state{accepts = Accepts + 1}};
        {error, closed} ->
            %% Parent process finished, so no worries here -- just shut down
            {stop, normal, State};
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

% Private functions

callback({M, F}, Socket) ->
    M:F(Socket);
callback(Fun, Socket) when is_function(Fun) ->
    Fun(Socket).
