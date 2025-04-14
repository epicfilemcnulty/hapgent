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
   and port, sends the payload and reads an answer.
 * Agent answers with the server's status, and, optionally, weight.
 * Depending on the answer HAProxy may change the current status or weight of the server.

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
  server srv2 10.42.42.11:8080 weight 50
```

We define two health checks here:

 1. HTTP health check using `GET` HTTP method to the `/health` uri,
    with `Host` header set to `my.service.com`
 2. Agent check, port 9777, every 5 seconds, no payload. Since the `agent-addr` option is absent,
    HAProxy will use server's IP as the agent IP address.

Pay attention to the fact that the weight reported by the agent is interpreted as
a percent of the original weight defined in the backend configuration.

For example, using the configuration above, if we set the weight of 
the agent on `srv2` to `50`, the effective weight for the `srv2` will be `25`.

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
* The `maxconn` field, if set, should be a number in the range `0-65535`.

For example:

```json
{"status":"UP"}

{"status":"READY","weight":100}

{"status":"DOWN","maxconn":10}

{"status":"UP","maxconn":300,"weight":77}
```

If *hapgent* fails to read or parse the state file during the initial startup, 
or upon receiving a HUP signal, it resets its state to the default value `{"status":"FAIL"}`.
Previous state value is **discarded** in this case.

## Usage

*hapgent* typically should be run as a systemd/SysV service on the same instance
where your service is deployed. See the deployment section below for details.

You can dynamically change *hapgent's* state with signals:

* On a `USR2` signal, hapgent sets the status to `DOWN`, and saves its state in the state file. 
* On a `USR1` signal, hapgent sets the status to `UP`, and saves its state in the state file.
* On a `HUP` signal, hapgent tries to read the state from the state file. If it succeeds,
  it sets its current state to the one read from the state file. If it fails to read or 
  parse the state file, it sets its state to the default value `{"status":"FAIL"}`.

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

### Binary releases for Linux x86_64 systems

Grab the `hapgent` binary, `hapgent.sha256` SHA256 checksum and `hapgent.sig` signature files
from the latest release [binary](https://github.com/epicfilemcnulty/hapgent/releases)

Make sure that SHA256 checksum of the binary matches the one in the `hapgent.sha256` file.

The binary is signed with my SSH key, to verify the signature you need to

1. Add my public key to the allowed signers file:

   ```
   echo "vladimir@deviant.guru ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICEWU0xshVgOIyjzQEOKtjG8sU8sWJPh25CP/ISfJRey" >> ~/.ssh/allowed_signers
   ```
2. Verify the signature:
   
   ```
   $ ssh-keygen -Y verify -f ~/.ssh/allowed_signers -n file -I vladimir@deviant.guru -s hapgent.sig < hapgent
   Good "file" signature for vladimir@deviant.guru with ED25519 key SHA256:K0hZF19Go+RKQPczS905IFVhRL8NiZTvZyi+4PkV/g8
   ```

### Building from source

You need [zig](https://ziglang.org/) version `0.14.0` to build from source.
Having zig installed and in the path, clone the repo and do the build:

```
git clone https://github.com/epicfilemcnulty/hapgent.git
cd hapgent
zig build
```

The binary is saved in the `zig-out/bin/hapgent` file.

## Resource usage

*Hapgent* is a very lightweight application, the binary is **75Kb** and memory usage during 
the runtime is about **200Kb**.

I've written a couple of HAProxy agent implementations in Go for different projects, and, for
comparison, the binary of my last Go implementation (same functionality as this one) is **3.8Mb**, 
memory usage is around **4.6Mb** during runtime.

## Deployment

There is an ansible [role](deploy/hapgent_ansible_role) to install,
configure and run `hapgent` as a systemd service under an unprivileged user on a Debian system.

It's configurable with the following ansible variables:

| Variable Name                  | Default                                                               |
|--------------------------------|-----------------------------------------------------------------------|
| `hapgent_version`              | *0.3.2*                                                               |
| `hapgent_user`                 | *nobody*                                                              |
| `hapgent_group`                | *group*                                                               |
| `hapgent_checksum`             | *38b9b2f80fbdf046311127b22943efb464081812bf53de7ce0452968c916b434*    |
| `hapgent_ip`                   | *0.0.0.0*                                                             |
| `hapgent_port`                 | *9777*                                                                |
| `hapgent_state_file`           | */etc/hapgent/state.json*                                             |
| `hapgent_status`               | *FAIL*                                                                |
