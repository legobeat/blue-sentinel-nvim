blue-sentinel-nvim
============

**Blue Sentinel** is a family of cross-editor **collaborative editing** plugins.

It supports multiple text editors, presently Neovim and VSCode, with a protocol meant to allow extension to other editors in the future.

* [Design document](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Design-Document)
* [Protocol](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Protocol)
* [Deploy a server](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Deploy-a-server)
* [API](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/API)
* [Commands](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Commands)
* [Technical Overview](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Technical-Overview)

[![Untitled-Project.gif](https://i.postimg.cc/50vfZ6Wr/Untitled-Project.gif)](https://postimg.cc/yg1qR6dh)

Features
--------

* Powerful collaborative editing algorithm

* UTF-8 Support

* Single or multiple buffer sharing

* Virtual cursors with username of other clients

* Spectate actions of a user

* Built-in localhost server

* Separated undo/redo for each user

* Persistent data on server

Requirements
------------

* Neovim 0.4.4 or above

Install
-------

Install using a plugin manager such as [vim-plug](https://github.com/junegunn/vim-plug).

```
Plug 'letsbreelhere/blue-sentinel-nvim'
```

Configurations
--------------

* Set your username in `init.vim`:

```
let g:blue_sentinel_username = "USERNAME"
```

See [here](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Customization) for more customization options.

Usage
-----

The collaborative editing plugin works with a server which connects together the clients. Thus, a server must be running which must be reachable by all clients.

### Server (Neovim or node.js)

For a localhost or LAN network, you can simple use the built-in server included in the plugin.

* Start it with `:BlueSentinelStartServer [host] [port]`
* When done stop it with `:BlueSentinelStopServer`

The default is to serve localhost only, on port 8080. For a more advanced (remote server) overview see [Deploy a server](https://github.com/letsbreelhere/blue-sentinel-nvim/wiki/Deploy-a-server)

### Client (Neovim)

To start the client, the first user to connect to the server must initiates the share with a special commands with has the form `BlueSentinelStart...`. Subsequent joining clients, use a different command `BlueSentinelJoin...`. Having distinct commands to start and join a server ensures that files are not overwritten by accident on connection.

There are essentially two modes of sharing at the moment.

* **Single buffer sharing**: This will only share the current buffer. 
* **Session sharing**: This will share all opened (and newly opened) buffers with the other clients. This can be thought of directory sharing without implicit writing on the file system.

For single buffer sharing use:
* `:BlueSentinelStartSingle [host] [port]` : Host is the URL or IP address. Port is 80 by default. Use this command if you're the first client to connect.
* `:BlueSentinelJoinSingle [host] [port]` : Use this command if another client already initiated a single share.
* `:BlueSentinelStop` : This will stop the client

For session sharing:

* `:BlueSentinelStartSession [host] [port]` : If you're the first client to connect.
* `:BlueSentinelJoinSession [host] [port]` : Use this command if another client already initiated a session share
* `:BlueSentinelStop`

Additional useful sharing commands are:

* `:BlueSentinelStatus` : Display the current connected clients as well as their locations
* `:BlueSentinelFollow [user]`
* `:BlueSentinelStopFollow`
* `:BlueSentinelOpenAll` : Open all files in buffers in the current directory. Useful to share the whole directory in session sharing.
* `:BlueSentinelSaveAll` : Save all opened buffers automatically. This will also create missing subdirectories.
* `:BlueSentinelMark` : Visually mark a region
* `:BlueSentinelMarkClear`

### Tips and Tricks

* If there is an issue, you can resync by stopping and reconnecting.
* In session sharing, view all the available buffers with `:ls`.

### Help

* If you encounter any problem, please don't hesitate to open an [Issue](https://github.com/letsbreelhere/blue-sentinel-nvim/issues)
### Contributions

* All contributions are welcome
