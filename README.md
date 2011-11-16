inv_tcps
========

inv_tcps is a fairly fast TCP acceptor library for Erlang applications. It
consists of a `gen_server` that creates a TCP listening socket and several
sub-processes for handling connections.

Connection handling is performed in the acceptor process itself, so a common use
case will be to send messages to other processes from within the acceptor for
most asynchronous calls; this will allow the acceptor to handle new connections
extremely quickly.

inv_tcps includes a rudimentary algorithm for spawning new child processes
on-demand: upon creation of a new listener, an initial and maximum number of
acceptors can be specified. The number of available acceptors never drops below
the initial amount and never exceeds the maximum amount.

Compiling
---------

inv_tcps uses the excellent [rebar](https://github.com/basho/rebar) tool. To compile
inv_tcps, execute `./rebar compile` in the project root.

Playing around
--------------

Head into the `ebin` directory and start up an Erlang shell:

    $ erl +K true +A 20
    1> application:load(inv_tcps), application:start(inv_tcps).

Before we continue, we need to define a callback function. The callback can be a
`fun()` or a tuple containing `{Module, Function}`.

A callback accepts a `socket()` (as returned by `gen_tcp:accept/1,2`). You can
perform all the usual operations on the socket, including `gen_tcp:recv/2,3`,
`gen_tcp:send/2` and `gen_tcp:close/1`. If the callback function returns without
closing the socket, it will automatically be closed by inv_tcps; socket
finalization will also occur if the callback throws an exception.

Let's create a simple echo server, since it's one of the more straightforward
examples:

    2> EchoServer = fun(Socket) ->
    2>     Runner = fun(Self) ->
    2>         case gen_tcp:recv(Socket, 0) of
    2>             {ok, Packet} ->
    2>                 io:format("~p received ~s~n", [self(), Packet]),
    2>                 gen_tcp:send(Socket, Packet),
    2>                 Self(Self);
    2>             Error ->
    2>                 ok
    2>         end
    2>     end,
    2>     Runner(Runner)
    2> end.

We exploit a bit of anonymous function trickery to get the callback to call
itself for more data; obviously if we were not using anonymous functions we
could avoid jumping through that hoop. Otherwise, the code is fairly
straightforward: receive data on the socket, print out an informational line,
and then send the data back. Rinse and repeat.

Now let's create a listening socket for our server:

    3> {ok, Pid} = inv_tcps:start([{port, 8080}, {callback, EchoServer}]).

With a little luck, you should get a response of something like
`{ok, <0.41.0>}`. Test out your server by running `telnet localhost 8080` and
typing a line or two; you should receive a reply. Open another telnet session
(while the first one is still running) and you should also receive replies
immediately in that session.

You can get a list of active acceptors by calling `inv_tcps:active(Pid)`
(likewise, a list of inactive acceptors can be obtained by calling
`inv_tcps:idle(Pid)`).

Pretty cool, huh?

Tuning
------

The main tuning options for inv_tcps are the `initial_pool_size` and
`maximum_pool_size` arguments used when creating an acceptor pool. These default
to `1` and `infinity` respectively, which is not terribly efficient.

After some very basic testing, using 20 asynchronous threads with an
`initial_pool_size` of `4` and a `maximum_pool_size` of `16` yielded fairly good
results (a Hello-World-style Web server handled between 7,000 and 10,000
requests per second in a VM). The syntax for this is as follows:

    4> {ok, Pid2} = inv_tcps:start([{port, 8081}, {callback, YourCallback},
                                    {initial_pool_size, 4},
                                    {maximum_pool_size, 16}]).

Using inv_tcps in your project
------------------------------

inv_tcps is effectively a `gen_server`, so it should be properly supervised in
your application. The functions `inv_tcps:start_link/1,2` call and return the
value of `gen_server:start_link/1,2` respectively.

Your supervisor's `init/1` might look like

    init([]) ->
        Listener = {myapp_test, {myapp_test, start_link, []},
                    permanent, 5000, worker, [myapp_test]},
        Processes = [Listener],
        {ok, {{one_for_one, 5, 10}, Processes}}.

And `myapp_test` should be something like the following (exports removed for
brevity):

    start_link() ->
        inv_tcps:start_link({local, ?MODULE},
                            [{port, 8080}, {callback, {?MODULE, accept}}]).

    accept(Socket) ->
        %% Process connection
        ok.

There's also a [working sample project](http://github.com/invectorate/inv_tcps_echoserver)
which could serve as a starting point for your own application!
