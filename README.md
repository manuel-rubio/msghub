msghub
=====

An OTP application

Play
----

    $ rebar3 do compile, shell

This way you'll have a shell opened to try commands and show the logs. Then,
you can use the following ways to access to the data:

TCP
---

In another shell you can execute the following command:

    $ telnet 127.0.0.1 5555
    SUBSCRIBE channel1
    OK
    PUBLISH channel1 hello world!
    OK
    hello world!
    QUIT

UDP
---

You can use _netcat_ (`nc` command) for TCP or UDP, but I think there are no a
lot of options to work with UDP so:

    $ nc -u 127.0.0.1 5555
    SUBSCRIBE channel1
    OK
    PUBLISH channel1 hello world!
    OK
    hello world!
    ^C

Note that the only way to exit from `nc` is pressing Ctrl+C.
