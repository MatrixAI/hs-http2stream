# Definitions From https://tools.ietf.org/html/rfc7540#section-3 (HTTP2)
client:  The endpoint that initiates an HTTP/2 connection.  Clients
  send HTTP requests and receive HTTP responses.

connection:  A transport-layer connection between two endpoints.

connection error:  An error that affects the entire HTTP/2
  connection.

endpoint:  Either the client or server of the connection.

frame:  The smallest unit of communication within an HTTP/2
  connection, consisting of a header and a variable-length sequence
  of octets structured according to the frame type.

peer:  An endpoint.  When discussing a particular endpoint, "peer"
  refers to the endpoint that is remote to the primary subject of
  discussion.

receiver:  An endpoint that is receiving frames.

sender:  An endpoint that is transmitting frames.

server:  The endpoint that accepts an HTTP/2 connection.  Servers
  receive HTTP requests and send HTTP responses.

stream:  A bidirectional flow of frames within the HTTP/2 connection.

stream error:  An error on the individual HTTP/2 stream.

# Personal Glossary
A bytestream: Allows us to read and write to/from the remote.

A bytestream muxer: A way to write data from multiple services on the host to a single bytestream.

A multiplexed bytestream: The bytestream that is produced by a bytestream muxer. In other words, a bytestream that communicates the data of many services between a host and a remote.

A bytestream demuxer: A way to read data from a multiplexed bytestream, and send the data to the appropriate service handler, of which there may be many.

A service: Represents an arbitrary behaviour that runs between a host and remote, and that relies on data that is communicated between the two. Examples include a program that echos data back to the remote, or a program that receives a HTTP request, and replies with some HTTP response (a website). Or it may not send data back to the service at all, and perform some side effectful action on the host. 
Another way to think of a service is as a distributed computation, between two endpoints of a connection. To allow the distributed computation to work, data must be passed between the two endpoints.

Service data: Data that is passed between a host and remote.

A service handler: A type or typeclass used to implement a service. It receives byte data from a remote (through either a regular bytestream or a multiplexed bytestream, although the service handler should be uncoupled from these concepts and instead provide a function that represents passing data to the service handler), and performs the behaviour associated with the service that it implements.

A remote: One of the two computing devices that is used to implement a service. It is the device that we have do not have any control over what actions that it performs.

A host: One of the two computing devices that is used to implement a service. This is the device that we have control over (the device on which our code runs). This device may implement many services between different remotes.

A transport: A way to create a connection between a host and remote. This is usually named by the network layer that allows us to create the connection, for example, TCP or WebSockets. The remote must support the transport for a connection to be made. The implementation of a transport will usually be to provide two ways to create a connection: by initiating a connection as the host to the remote (dialing), or by receiving a request to open a connection from a remote (listening). Conventionally, a listener object is bound for the purposes of listening forincoming connections on the particular network layer that the transport operates on.

A discovery: A way to find new remote devices that we can open a new connection to. Another way to think of this is as a way to produce a graph of peers that can be connected to.

A connection: Allows us to open multiple bytestreams to a single remote.
A bytestream: Allows us to read and write to/from the remote.
A bytestream muxer: A way to write data from multiple services on the host to a single bytestream.
A multiplexed bytestream: The bytestream that is produced by a bytestream muxer. In other words, a bytestream that communicates the data of many services between a host and a remote.
A bytestream demuxer: A way to read data from a multiplexed bytestream, and send the data to the appropriate service handler, of which there may be many.
A service: Represents an arbitrary behaviour that runs between a host and remote, and that relies on data that is communicated between the two. Examples include a program that echos data back to the remote, or a program that receives a HTTP request, and replies with some HTTP response (a website). Or it may not send data back to the service at all, and perform some side effectful action on the host. 
Another way to think of a service is as a distributed computation, between two computing devices. To allow the distributed computation to work, data must be passed between the two computing devices.
Service data: Data that is passed between a host and remote.
A service handler: A type or typeclass used to implement a service. It receives byte data from a remote (through either a regular bytestream or a multiplexed bytestream, although the service handler should be uncoupled from these concepts and instead provide a function that represents passing data to the service handler), and performs the behaviour associated with the service that it implements.
A remote: One of the two computing devices that is used to implement a service. It is the device that we have do not have any control over what actions that it performs.
A host: One of the two computing devices that is used to implement a service. This is the device that we have control over (the device on which our code runs). This device may implement many services between different remotes.
A transport: A way to create a connection between a host and remote. This is usually named by the network layer that allows us to create the connection, for example, TCP or WebSockets. The remote must support the transport for a connection to be made. The implementation of a transport will usually be to provide two ways to create a connection: by initiating a connection as the host to the remote (dialing), or by receiving a request to open a connection from a remote (listening). Conventionally, a listener object is bound for the purposes of listening forincoming connections on the particular network layer that the transport operates on.
A discovery: A way to find new remote devices that we can open a new connection to. Another way to think of this is as a way to produce a graph of peers that can be connected to.
A peer routing: 
A record store:
A distributed record store:
A crypto: A way to encrypt a bytestream so that only the host and remote devices can read the data. This can be thought of as a plugin for a connection; all bytestreams that are opened by the connection will be encrypted with the crypto.
A node: A high-level interface that depends on transports, bytestream muxers, discovery. It's primary behaviour is to open services between the host that it runs on, and one or more remotes. Secondary behaviours include functions that run when a new remote is connected to
A peer: A synonym for a remote device that can be connected to, and which many services can be opened on.

A peer routing: 

A record store:

A distributed record store:

A crypto: A way to encrypt a bytestream so that only the host and remote devices can read the data. This can be thought of as a plugin for a connection; all bytestreams that are opened by the connection will be encrypted with the crypto.

A node: A high-level interface that depends on transports, bytestream muxers, discovery. It's primary behaviour is to open services between the host that it runs on, and one or more remotes. Secondary behaviours include functions that run when a new remote is connected to

A peer: A synonym for a remote device that can be connected to, and which many services can be opened on.

