# Testing

```sh
v test .
```

The suite has three kinds of tests:

- **Unit tests** for configuration parsing and validation, the logger, message
encoding and decoding (round trips, fixed byte vectors, truncated input), share
scanning and search, the upload queue, and the pid file.
- **Integration tests** in `lib/slsknet/integration_test.v`. They start a
scripted fake Soulseek server and a fake remote peer on localhost, and check
login, rejected credentials, relayed searches, browse, user info, refused requests,
a complete upload with a resume offset, a declined upload, and the distributed
parent flow.
- **Manual checks** with the daemon against a fake server script, covering
`--daemon`, the pid file, `SIGHUP` reload, `SIGTERM` shutdown, reconnection and
exit codes.

The integration tests check the daemon against the message formats the code
expects. On their own they do not prove compatibility with other clients.

File uploads and search are tested manually with Nicotine+ client.
