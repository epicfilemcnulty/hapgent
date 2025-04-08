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

While the first three types of these checks are internal to HAProxy, i.e. 
you don't need any external tools to use them, the agent checks are different: 
you need to have an actual agent running on the upstream servers to use agent checks. 

*Hapgent* is an implementation of such an agent.

## Agent protocol

The protocol of HAProxy agent is described in the [agent checks](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/service-reliability/health-checks/#agent-checks) section of the official documentation, but in a nutshell it works
like this:

    * You define *address*, *port*, *payload* and *interval* for the agent in the upstream server configuration.
    * Every *N* seconds (where N == interval) HAProxy makes a TCP connection to the defined address 
      and port, sends the payload and reads the answer.
    * Depending on the answer HAProxy can change the server status (up/down) and/or change its weight.

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

*hapgent* gives you a mechanism to put an instance in or out of load balancing:

```bash
#!/bin/bash
# a sample deployment script for a service

echo "Removing the instance from LB"
pkill -USR2 hapgent # assuming that we have only one hapgent per instance

docker stop "${SERVICE_NAME}"
docker rm "${SERVICE_NAME}"

# here we deploy a new version of a service,
# do health checks and finally
# put the instance back to LB

echo "Putting the instance back to LB"
pkill -USR1 hapgent
```

or dynamically adjust instance's weight or maxconn number.

## Installation

### Binary releases

### Building from source

## Deployment
