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

inv_tcps uses the excellent [rebar](http://hg.basho.com/rebar/) tool. (For now,
actual releases aren't really handled but this functionality will be available
soon.)

To compile inv_tcps, execute `./rebar compile` in the project root.

Playing around
--------------

Head into the `ebin` directory and start up an Erlang shell:

    $ erl +K true +A 20
    1> application:load(inv_tcps), application:start(inv_tcps).

This starts the inv_tcps supervisor. Before we continue, we need to define a
callback function. The callback can be a `fun()` or a tuple containing
`{Module, Function}` or `{Module, Function, Args}`.

A callback accepts a `socket()` (as returned by `gen_tcp:accept/1,2`). In the
case of a `{Module, Function, Args}` callback, the socket is prepended to the
argument list (`[Socket | Args]`). You can perform all the usual operations on
the socket, including `gen_tcp:recv/2,3`, `gen_tcp:send/2` and
`gen_tcp:close/1`. If the callback function returns without closing the socket,
it will automatically be closed by inv_tcps; socket finalization will also occur
if the callback throws an exception.

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

    4> {ok, Pid2} = inv_tcps:start([{port, 8080}, {callback, YourCallback},
                                    {initial_pool_size, 4},
                                    {maximum_pool_size, 16}]).
