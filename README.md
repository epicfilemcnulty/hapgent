# HAProxy Agent

## Introduction

*Hapgent* is a companion tool for the [HAProxy](https://www.haproxy.com/) load balancer.

When you have a bunch of upstream servers defined for an HAProxy backend, 
HAProxy has [several](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/service-reliability/health-checks) types of
health checks to determine the availability of an upstream server:
    
    1. TCP health checks
    2. HTTP health checks
    3. Passive health checks
    4. Agent checks

While the first three types are internal to HAProxy, i.e. 
you don't need any external tools to use them, the agent checks are different: 
you need to have an actual agent running on the upstream servers to use agent checks. 

*Hapgent* is an implementation of such an agent.

## Agent protocol

The protocol of HAProxy agent is described in the [agent checks](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/service-reliability/health-checks/#agent-checks) section of the official documentation, but in a nutshell it works
like this:

    * You define *address*, *port*, *payload* and *interval* for the agent in the upstream server configuration.
    * Every *interval* seconds HAProxy makes a TCP connection to the defined address 
      and port, sends the payload and reads the answer.
    * Depending on the answer HAProxy can change the server status (up/down) and/or change its weight.

### HAProxy backend configuration sample

```
backend sample
  mode http
  balance roundrobin
  option forwardfor if-none
  option httpchk
  default-server check agent-check agent-port 9777 agent-inter 5s
  http-check send meth GET uri /health ver HTTP/1.1 hdr Host my.service.com
  server srv1 10.42.42.10:8080 weight 100
  server srv1 10.42.42.11:8080 weight 50
```

Note that the protocol allows sending arbitrary payload to the agents with
the `agent-send` option. The agents could use this to implement multiple states support.

*Hapgent* itself, however, just ignores the payload in the incoming requests.
If you need multiple states, i.e. you have multiple services on the same backend 
server, just run an instance of *hapgent* per service, using different ports. 

## Configuration

*Hapgent* is configured via the environment variables:

| Variable Name                  | Default   |
|--------------------------------|-----------|
| `HAPGENT_IP`                   | *0.0.0.0* |
| `HAPGENT_PORT`                 | *9777*    |
| `HAPGENT_STATE_FILE`           | */etc/hapgent/state.json* |


### State file format

Upon initialisation *hapgent* reads the state file at the path defined
in the `HAPGENT_STATE_FILE` environment variable.

The state file must be a valid JSON object with the required field `status`,
and optional fields `weight` and `maxconn`.

* Valid values for the `status` field are `UP`,`DOWN`,`READY`,`DRAIN`,`FAIL`,`MAINT`,`STOPPED`.
* The `weight` field, if set, should be a number in the range `0-255`.
* The `maxconn` field, if set, should be a number in the range of `0-65535`.

For example:

```json
{"status":"UP"}

{"status":"READY","weight":100}

{"status":"DOWN","maxconn":10}

{"status":"UP","maxconn":300,"weight":77}
```

If *hapgent* fails to read or parse the state file during the initial startup, 
or upon receiving a HUP signal, it resets its state to the default value `{"status":"MAINT"}`.  
Previous state value is **discarded**.

## Usage

*hapgent* should be run as a systemd/SysV service on the same instance
where your service is deployed. You can dynamically change its state
with signals:

* On a `USR2` signal, hapgent sets the status to `DOWN`, and saves its state in the state file. 
* On a `USR1` signal, hapgent sets the status to `UP`, and saves its state in the state file.
* On a `HUP` signal, hapgent tries to read the state from the state file. If it succeeds,
  it sets its current state to the one read from the state file. If it fails to read or 
  parse the state file, it sets its state to the default value `{"status":"MAINT"}`.

### Putting an instance **in** or **out** of load balancing

This can be done in a deployment script, e.g.:

```bash
#!/bin/bash
# a sample deployment script for a service

echo "Removing the instance from LB"
pkill -USR2 hapgent # assuming that we have only one hapgent per instance

stop_service ${SERVICE_NAME}
deploy_new_version ${SERVICE_NAME}
start_service ${SERVICE_NAME}

echo "Putting the instance back to LB"
pkill -USR1 hapgent
```

### Dynamic weight adjustment

While it's tempting to have a dynamic weight calculation
feature as a builtin in a HAProxy agent, it's not always 
a good idea.

*Hapgent* is intentionally designed to be as simple as possible,
so it does not change anything in its current state on its own.
It simply reports its state upon receiving a TCP connection.

But *hapgent* can be operated with the help of Unix signals,
as described above. Particularly, on the `SIGHUP` signal *hapgent*
tries to re-read the state from the state file. This can be used
to implement a generic weight / maxconn adjustment system:

1. Create a script/app that calculates the weight for the instance based on the criteria you want.
2. Create a cron task to periodically run said script, update the weight in the *hapgent's* state
   file, and send the `SIGHUP` signal to *hapgent*.

## Installation

### Binary releases

### Building from source

You need [zig](https://ziglang.org/) version `0.14.0` to build from source.
Having zig installed and in the path, clone the repo and do the build:

```
git clone https://github.com/epicfilemcnulty/hapgent.git
cd hapgent
zig build
```

The binary is saved in the `zig-out/bin/hapgent` file.

## Deployment
