# yell
Everything that is received from stdin and clients is sent to stdout and all other clients, except that stdin is not send to stdout.

To run:
```bash
make
./yell 0.0.0.0 37812
```
And then open as many connections as you like (e.g. with netcat)
