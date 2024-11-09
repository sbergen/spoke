## High level

- [x] TCP
- [ ] WebSocket

- [ ] Better error handling in client

- [x] Connect
- [x] Subscribe
- [ ] Pings
- [x] Receive messages
- [x] Send messages
- [ ] Retry failed sub/unsub
- [ ] Graceful shutdown

- [ ] QoS 0
- [ ] QoS 1
- [ ] QoS 2
- [ ] Auth
- [ ] Session management (clean flag)
- [ ] Will

## Packet type encoding/decoding

Only covered for client's needs (e.g. only encode CONNECT).

- [/] CONNECT
- [x] CONNACK
- [x] PINGREQ
- [x] PINGRESP
- [x] SUBSCRIBE
- [x] SUBACK
- [/] PUBLISH
- [ ] UNSUBSCRIBE
- [ ] UNSUBACK
- [x] DISCONNECT

### QoS 1 and 2
- [ ] PUBACK
- [ ] PUBREC
- [ ] PUBREL
- [ ] PUBCOMP