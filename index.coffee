#
# DEBUG=* nodemon -x iced index.coffee
#

require 'shelljs/global'
path = require 'path'
{join} = path
cli = require 'cli'
chokidar = require 'chokidar'
_ = require 'underscore'
require 'colors'
ascii = require './ascii'
#nodemon = require 'nodemon'
monitor = require 'usb-detection'
{EventEmitter} = require 'events'
telnet = require 'telnet-client'
require 'iced-coffee-script'
debug = require('debug') 'main'
getopt = require 'node-getopt'
parseArgs = require 'minimist'

# TODO: CLI

opts = getopt.create
  dir: ['d', 'Project dir']
  name: ['n', 'Executable name']
  gccTools: ['g', 'GCC tools dir']
.parseSystem()

console.log opts

# Store process object for openocd instance.
proc = null

pubsub = new EventEmitter

projDir = opts.dir or '/Users/Vaughan/dev-tracktics/tracktics-tracker-cube'
projName = opts.name or 'tracktics-tracker-cube'

searchPaths = "-s #{projDir}"
configFiles = "-f openocd/st_nucleo_f4.cfg"
cmd = "openocd #{searchPaths} #{configFiles}"
gccTools = "~/dev-embedded/gcc-arm-none-eabi-4_8-2014q1/bin" or opts.gccTools

debug cmd

monitor.on 'add', (device) ->
  if device.deviceName is 'STM32 STLink'
    pubsub.emit 'stLinkConnected'

# Run and try to reconnect every second if there is a failure.
run = ->
  debug 'Connecting...'.bold
  proc = exec cmd, {async: true}, (code, output) ->

    # Openocd shutdown.

    if output.match 'Error: open failed'
      # Device is probably disconnected. 
      debug 'Device is probably disconnected. Will try to connect when device is detected again.'.red
      pubsub.once 'stLinkConnected', -> run()
      return

    if output.match 'Error: read version failed'
      debug 'OpenOCD needs to restart'.red
      run()
      return
      # Try to rerun after a second.
      #setTimeout ->
      #  run()
      #, 1000

    if output.match 'undefined debug reason 7 - target needs reset'
      debug '-> undefined debug reason 7 - target needs reset'.red
      debug 'WHAT THE FUCK. Need to start debug session again.'.red
      # TODO: Google this error and figure it out.
      # Maybe this...
      return

run()



# This is for automatically flashing changes.


# TODO: Automatically flash when binary output file changes.

debugDir = "#{projDir}/Debug"
elf = "#{debugDir}/#{projName}.elf"
out = "#{debugDir}/#{projName}.bin"
objcopy = "#{gccTools}/arm-none-eabi-objcopy"
objcopyCmd = "#{objcopy} -O ihex #{elf} #{out}"

#flash write_image erase #{elf} 0x08000000
# For flashing with telnet.
cmdsString = """
  reset halt
  flash probe 0
  #{#flash protect 0 0 0 off}
  #{#stm32f2x unlock 0}
  flash write_image erase #{elf}
  reset
  exit
"""

flashOnChange = ->

  output = join(projDir, "Debug/#{projName}.elf")

  flash = ->
    debug 'Flashing...'.bold
    cmds = cmdsString.split '\n'
    proc.stdin.write 'flash init\n'

    # To commmunicate with openocd we have a few options:-
    # - openocd cfg commands (e.g. `-c flash init`)
    # - telnet 
    # - gdb 
    # - tcl

    # We use telnet here, it is the simplest.

    # Due to a bug in Eclipse GNU ARM, the Create Flash Image tool doesn't work
    # so we have to extract our own flash image from the elf.
    exec objcopyCmd

    # Here we use telnet to flash our shit.
    conn = new telnet
    params = 
      host: 'localhost'
      port: 4444
      shellPrompt: '> '
    conn.on 'ready', ->
      for cmd in cmds
        debug cmd
        await conn.exec cmd, defer resp
        debug resp
    conn.on 'exit', ->
      debug 'Telnet exited'
    conn.connect params

  onChange = _.debounce (p, stats) ->
    debug 'Connecting...'.bold
    debug "Changed: #{p}"
    proc.kill 'SIGINT' if proc 
    proc = exec cmd, async: true # TODO: Use `run` from above instead.
  , 200 # We need to debounce because it is called twice in 100ms.
  , true # Immediate.

  watcher = chokidar.watch output, ignoreInitial: false

  # We don't start a new openocd on compile.
  #watcher.on 'change', -> debug arguments
  #watcher.on 'change', onChange
  #watcher.on 'add', onChange # Runs on first load.

  watcher.on 'change', _.debounce ->
    flash()
  , 200

  # TODO: Retry if `Error: read version failed`.
  #   Should probably fix in openocd instead.

flashOnChange()
