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
%%
%% Portions of this file extracted from MochiWeb, copyright (c) 2007 Mochi
%% Media, Inc.

-module(inv_tcps).

-behaviour(gen_server).

%% API
-export([start/1, stop/1]).
-export([port/1, idle/1, active/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Records
-record(inv_tcps_state, {listener, port, supervisor,
                         initial_pool_size, maximum_pool_size,
                         active = sets:new(), active_size = 0,
                         idle = sets:new(), idle_size = 0}).

%% Defaults
-define(DEFAULT_INITIAL_POOL_SIZE, 1).
-define(DEFAULT_MAXIMUM_POOL_SIZE, infinity).

-define(DEFAULT_BACKLOG, 128).
-define(DEFAULT_NO_DELAY, false).
-define(DEFAULT_BUFFER_SIZE, 8192).

%% ===================================================================
%% API functions
%% ===================================================================

start(Args) ->
    gen_server:start_link(?MODULE, Args, []).

port(Pid) ->
    case gen_server:call(Pid, port) of
        {ok, Port} ->
            Port;
        Error ->
            Error
    end.

idle(Pid) ->
    gen_server:call(Pid, idle).

active(Pid) ->
    gen_server:call(Pid, active).

stop(Pid) ->
    gen_server:cast(Pid, stop).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init(Args) ->
    %% Get initial options
    process_flag(trap_exit, true),

    InitialSize = proplists:get_value(initial_pool_size, Args, ?DEFAULT_INITIAL_POOL_SIZE),
    MaximumSize = proplists:get_value(maximum_pool_size, Args, ?DEFAULT_MAXIMUM_POOL_SIZE),

    Callback = proplists:get_value(callback, Args, fun(_) -> ok end),

    Host = proplists:get_value(host, Args, any),
    Port = proplists:get_value(port, Args, 0),
    Backlog = proplists:get_value(backlog, Args, ?DEFAULT_BACKLOG),
    NoDelay = proplists:get_value(no_delay, Args, ?DEFAULT_NO_DELAY),
    BufferSize = proplists:get_value(buffer_size, Args, ?DEFAULT_BUFFER_SIZE),

    %% Set up TCP options
    TcpOptions0 = [binary,
                   {reuseaddr, true},
                   {packet, 0},
                   {backlog, Backlog},
                   {active, false},
                   {nodelay, NoDelay},
                   {recbuf, BufferSize}],
    TcpOptions = case Host of
                     any ->
                         [inet, inet6 | TcpOptions0];
                     {_, _, _, _} ->
                         [inet, {ip, Host} | TcpOptions0];
                     {_, _, _, _, _, _, _, _} ->
                         [inet6, {ip, Host} | TcpOptions0]
                 end,

    %% Create listening socket
    State = #inv_tcps_state{initial_pool_size = InitialSize,
                            maximum_pool_size = MaximumSize},
    case gen_tcp:listen(Port, TcpOptions) of
        {ok, Listener} ->
            case supervise(State#inv_tcps_state{listener = Listener,
                                                port = inet:port(Listener)},
                           Callback) of
                {ok, NewState} ->
                    {ok, NewState};
                Error ->
                    {stop, Error}
            end;
        Error ->
            {stop, Error}
    end.

handle_call(port, _From, #inv_tcps_state{port = Port} = State) ->
    {reply, {ok, Port}, State};
handle_call(idle, _From, #inv_tcps_state{idle = Idle} = State) ->
    {reply, {ok, sets:to_list(Idle)}, State};
handle_call(active, _From, #inv_tcps_state{active = Active} = State) ->
    {reply, {ok, sets:to_list(Active)}, State};
handle_call(_Message, _From, State) ->
    {reply, ignore, State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({active, Pid}, #inv_tcps_state{idle = Idle0, idle_size = IdleSize,
                                           active = Active0, active_size = ActiveSize} = State) ->
    case sets:is_element(Pid, Idle0) of
        true ->
            Idle = sets:del_element(Pid, Idle0),
            Active = sets:add_element(Pid, Active0),
            NewState = State#inv_tcps_state{idle = Idle, idle_size = IdleSize - 1,
                                            active = Active, active_size = ActiveSize + 1},
            case supervise_children(NewState) of
                {ok, ChildState} ->
                    {noreply, ChildState};
                Error ->
                    {stop, Error, NewState}
            end;
        false ->
            {noreply, State}
    end;
handle_cast({idle, Pid}, #inv_tcps_state{idle = Idle0, idle_size = IdleSize,
                                         active = Active0, active_size = ActiveSize} = State) ->
    case sets:is_element(Pid, Active0) of
        true ->
            Active = sets:del_element(Pid, Active0),
            Idle = sets:add_element(Pid, Idle0),
            NewState = State#inv_tcps_state{idle = Idle, idle_size = IdleSize + 1,
                                            active = Active, active_size = ActiveSize - 1},
            case supervise_children(NewState) of
                {ok, ChildState} ->
                    {noreply, ChildState};
                Error ->
                    {stop, Error, NewState}
            end;
        false ->
            {noreply, State}
    end;
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, _Type, Pid, _Info},
            #inv_tcps_state{idle = Idle0, idle_size = IdleSize,
                            active = Active0, active_size = ActiveSize} = State) ->
    NewState = case sets:is_element(Pid, Idle0) of
                   true ->
                       Idle = sets:del_element(Pid, Idle0),
                       State#inv_tcps_state{idle = Idle, idle_size = IdleSize - 1};
                   false ->
                       case sets:is_element(Pid, Active0) of
                           true ->
                               Active = sets:del_element(Pid, Active0),
                               State#inv_tcps_state{active = Active, active_size = ActiveSize - 1};
                           false ->
                               State
                       end
               end,
    case supervise_children(NewState) of
        {ok, ChildState} ->
            {noreply, ChildState};
        Error ->
            {stop, Error, NewState}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #inv_tcps_state{listener = Listener}) ->
    %% The linked supervisor will be terminated when this process is terminated
    gen_tcp:close(Listener),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private functions

supervise(#inv_tcps_state{listener = Listener} = State, Callback) ->
    Owner = self(),
    Supervisor = inv_tcps_acceptor_sup:start_link(Listener, Callback,
                                                  fun(Pid) -> accepted(Owner, Pid) end,
                                                  fun(Pid) -> closed(Owner, Pid) end),

    case Supervisor of
        {ok, SupervisorPid} ->
            supervise_children(State#inv_tcps_state{supervisor = SupervisorPid});
        Error ->
            Error
    end.

supervise_children(#inv_tcps_state{
                      idle_size = IdleSize, active_size = ActiveSize,
                      initial_pool_size = InitialSize,
                      maximum_pool_size = MaximumSize} = State) when (IdleSize =:= 0 andalso
                                                                                       (MaximumSize =:= infinity orelse
                                                                                        ActiveSize < MaximumSize)) orelse
                                                                     IdleSize + ActiveSize < InitialSize ->
    case supervise_child(State) of
        {ok, NewState} ->
            supervise_children(NewState);
        Error ->
            Error
    end;
supervise_children(State) ->
    {ok, State}.

supervise_child(#inv_tcps_state{supervisor = Supervisor, idle = Idle0, idle_size = IdleSize} = State) ->
    case spawn_child(Supervisor) of
        {ok, Pid} ->
            Idle = sets:add_element(Pid, Idle0),
            {ok, State#inv_tcps_state{idle = Idle, idle_size = IdleSize + 1}};
        Error ->
            Error
    end.

spawn_child(Supervisor) ->
    case inv_tcps_acceptor:start(Supervisor) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            inv_tcps_acceptor:accept(Pid),
            {ok, Pid};
        Error ->
            Error
    end.

accepted(Owner, Pid) ->
    gen_server:cast(Owner, {active, Pid}).

closed(Owner, Pid) ->
    gen_server:cast(Owner, {idle, Pid}).
