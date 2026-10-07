# Pearfy FPS High Linux load client

This archive contains a one-run client configuration for the Pearfy FPS High benchmark server. It simulates 5,000 clients in 42 matches (41 matches of 120 and one of 80) and sends 60 encrypted binary UDP inputs per client per second for 10 seconds by default. The only runtime dependency is Node.js 18 or newer; the client uses Node's built-in modules and does not need `npm install`.

## Install and run

```sh
./install-deps.sh
./run-client.sh
```

To change the run length or the number of generator processes:

```sh
DURATION_SECONDS=10 GENERATOR_WORKERS=8 ./run-client.sh
```

The client writes `client-result.json`, `rtt-samples.csv` and `client.log` to `results/<UTC timestamp>/`. It binds its UDP socket to `0.0.0.0` so replies can arrive on the Linux machine's network interface. Set `CLIENT_BIND_HOST` only if that machine has multiple interfaces and a specific local address is needed.

## Server endpoint and session data

`client-config.json` contains the server address and one-time session keys generated for this benchmark run. It works only while the matching server process is running. Keep the archive private, do not post it publicly, and delete it after the run. The server and client must be able to exchange UDP packets on the configured port; both machines should be on a network that permits peer-to-peer UDP.

The server runs on a Mac at the address printed in `connection-info.txt`. The fixture is synthetic and intended for load measurement, not production use or a complete FPS game.
