func_callback_err = (err) -> console.log 'Error ' + err

check_command_msg = (message) ->
  if (message.charAt 0) is '/'
    return 'topic' if message.match //\/topic .*//i
    return true
  else
    log 'warn', 'Incorrect message ' + message
    return false
  false

log = (type, msg) ->
  color = "\u001b[0m"
  reset = "\u001b[0m"
  switch type
  case 'info'
    color = "\u001b[36m"
  case 'warn'
    color = "\u001b[33m"
  case 'error'
    color = "\u001b[31m"
  case 'msg'
    color = "\u001b[34m"
  default
    color = "\u001b[0m"
  console.log color + ' ' + type + ' - ' + reset + msg


$config =
  port: 8082,
  redis-host: '127.0.0.1',
  redis-port: 6379,
  socket-io-log-level: 2,
  redis:
    host: '127.0.0.1',
    port: 6379,
    key-history: \coscup_2013:chat:history
    key-topic: \coscup_2013:chat:topic
    key-notify: \coscup_2013:chat:notify

sanitize = (require 'validator').sanitize

# redis
Redis = require 'redis'
RedisStore = require 'socket.io/lib/stores/redis'

redis_pub = Redis.createClient $config.redis-port, $config.redis-host
redis_sub = Redis.createClient $config.redis-port, $config.redis-host

redis_client = Redis.createClient $config.redis-port, $config.redis-host
redis_history_client = Redis.createClient $config.redis-port, $config.redis-host

redis_pub.on 'error', func_callback_err
redis_sub.on 'error', func_callback_err
redis_client.on 'error', func_callback_err
redis_history_client.on 'error', func_callback_err

app = (require 'express')!
server = (require 'http').createServer app
io = (require 'socket.io').listen server
$client_count = 0

server.listen $config.port
io.set 'log level', $config.socket-io-log-level
io.set 'store', new RedisStore {
  redisPub: redis_pub
  redisSub: redis_sub
  redisClient: redis_client
}

app.get '/', (req, res) -> res.sendfile __dirname + '/index.html'
interval = setInterval (-> log 'info', 'Total client in this server: ' + $client_count), 10000
iTS = 0

status_update_interval = setInterval (-> iTS := (new Date).getTime!), 2000
status_update_interval = setInterval (->
  log 'info', 'Sending status-update event'
  redis_history_client.hgetall $config.redis.key-notify, (err, res) ->
    if res
      StatusObject = new Array
      for key of res
        if res.hasOwnProperty key
          data = new Object
          data.count = 1
          data.ts = res[key]
          data.room = key
          StatusObject.push data
      io.sockets.emit 'status_update', StatusObject
      redis_history_client.del $config.redis.key-notify), 10000

io.sockets.on 'connection', (socket) ->
  Info =
    nickname: '',
    root: '',
    id: socket.id

  $client_count++
  log 'info', '[' + Info.id + ']' + ' Connected'

  socket.on 'add_data', (data_obj) ->
    if not data_obj
      log 'info', '[' + Info.id + '] [add_data] data_obj null'
      return
    data_obj.nickname = (sanitize data_obj.nickname).xss!
    data_obj.nickname = (sanitize data_obj.nickname).entityEncode!
    data_obj.message = (sanitize data_obj.message).xss!
    data_obj.message = (sanitize data_obj.message).entityEncode!
    data_obj.ts = (new Date).getTime!
    Info.nickname = data_obj.nickname
    if not Info.room then log 'error', 'add_data: no room'
    data_obj.room = Info.room
    (socket.broadcast.to Info.room).emit 'updatechat', data_obj
    log 'info', '[' + Info.id + '] broadcast [updatechat] event to [' + Info.room + ']: ts=' + data_obj.ts + ',nickname=' + data_obj.nickname + ',message=' + data_obj.message
    redis_history_client.rpush "#{$config.redis.key-history}:#{Info.room}", JSON.stringify data_obj
    redis_history_client.ltrim "#{$config.redis.key-history}:#{Info.room}", -10, -1
    redis_history_client.hset $config.redis.key-notify, Info.room, data_obj.ts
  socket.on 'command_msg', (data_obj) ->
    if not data_obj
      log 'info', '[' + Info.id + '] [command_msg] null'
      return
    if not data_obj.message
      log 'info', '[' + Info.id + '] [command_msg] no message'
      return
    data_obj.message = (sanitize data_obj.message).xss!
    data_obj.message = (sanitize data_obj.message).entityEncode!
    data_obj.nickname = (sanitize data_obj.nickname).xss!
    data_obj.nickname = (sanitize data_obj.nickname).entityEncode!
    data_obj.ts = (new Date).getTime!
    log 'info', '[' + Info.id + '] [command_msg] event at [' + Info.room + '] receiving command msg ' + data_obj.message
    if (check_command_msg data_obj.message) is 'topic'
      (socket.broadcast.to Info.room).emit 'command_msg', data_obj
      socket.emit 'command_msg', data_obj
      redis_history_client.set "#{$config.redis.key-topic}:#{Info.room}", JSON.stringify data_obj
      redis_history_client.hset $config.redis.key-notify, Info.room, data_obj.ts
    else
      log 'info', '[' + Info.id + '] Incorrect command ' + message

  socket.on 'switchRoom', (new_room) ->
    if Info.room
      socket.leave Info.room
      log 'info', '[' + Info.id + '] [switchRoom] event, leave [' + Info.room + ']'
    new_room = (sanitize new_room).xss!
    new_room = (sanitize new_room).entityEncode!
    socket.join new_room
    Info.room = new_room
    log 'info', '[' + Info.id + '] [switchRoom] event, join [' + new_room + ']'

    redis_history_client.lrange "#{$config.redis.key-history}:#{new_room}", 0, -1, (err, data_array) ->
      return  if not data_array
      if data_array.length is 0 then return
      socket.emit 'updatehistory', new_room, data_array
      log 'info', '[' + Info.id + '] [switchRoom] event, at [' + new_room + '] , update-history send'

    redis_history_client.get "#{$config.redis.key-topic}:#{Info.room}", (err, data) ->
      if not data
        log 'info', '[' + Info.id + '] [switchRoom] event, at [' + new_room + '] , no topic set'
        return
      data_obj = JSON.parse data
      if not data_obj then log 'error', 'json parse error'
      ts = data_obj.ts
      message = data_obj.message
      nickname = data_obj.nickname
      data_obj.room = new_room
      log 'info', '[' + Info.id + '] [switchRoom] event, at [' + new_room + '] , topic=' + message
      socket.emit 'command_msg', data_obj

  socket.on 'disconnect', ->
    socket.leave Info.room
    log 'info', '[' + socket.id + '] ' + 'disconnected'
    $client_count--
