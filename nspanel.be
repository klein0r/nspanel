# Sonoff NSPanel Tasmota driver v0.47 | code by blakadder and s-hadinger
# Modified by klein0r - removed weather api, temperature sensor and default widgets
var mode = "NSPanel"
import persist
var devicename = tasmota.cmd("DeviceName")["DeviceName"]
persist.tempunit = tasmota.get_option(8) == 1 ? "F" : "C"
if persist.has("dim")  else   persist.dim = "1"  end
persist.save() # save persist file until serial bug fixed

class NSPanel : Driver
  # set thermostat options
  static atc = { 
    "id":     "thermostat",
    "outlet": "0",  # outlet to use for trigger
    "etype":  "hot", # hot or cold
    "mirror":  false, # if true Tasmota will resend triggers as commands to keep the state on screen
  }

  static types = {
    '"switches":[{"outlet":':     0x87,
    "relation":   0x86,
    "ATC":      0x84,
    "index":    0x86,
    "params":     0x86,
    "wifiState":  0x85,
    "HMI_resources":0x86,
    "temp":     0x83,
    "year":     0x82,
    "weather":    0x81,
    "queryInfo":  0x80,
    "HMI_dimOpen":  0x87,
  }
  static header = bytes('55AA') 

  var ser  # create serial port object

  # intialize the serial port, if unspecified Tx/Rx are GPIO 16/17
  def init(tx, rx)
    if !tx   tx = 16 end
    if !rx   rx = 17 end
    self.ser = serial(rx, tx, 115200, serial.SERIAL_8N1)
    tasmota.add_driver(self)
  end

  # determine type of message
  def findtype(value)
    import string
    for k:self.types.keys()
      if string.find(value, k) >= 0
        return self.types[k]
      end
    end
    return 0
  end

  def crc16(data, poly)
    if !poly  poly = 0xA001 end
    # CRC-16 MODBUS HASHING ALGORITHM
    var crc = 0xFFFF
    for i:0..size(data)-1
      crc = crc ^ data[i]
      for j:0..7
        if crc & 1
          crc = (crc >> 1) ^ poly
        else
          crc = crc >> 1
        end
      end
    end
    return crc
  end

  # encode using NSPanel protocol
  # input: payload:json string
  def encode(payload)
    var b = bytes()
    var nsp_type = self.findtype(payload)
    b += self.header
    b.add(nsp_type)       # add a single byte
    b.add(size(payload), 2)   # add size as 2 bytes, little endian
    b += bytes().fromstring(payload)
    var msg_crc = self.crc16(b)
    b.add(msg_crc, 2)       # crc 2 bytes, little endian
    return b
  end

  def split_55(b)
    var ret = []
    var s = size(b)   
    var i = s-1   # start from last
    while i > 0
      if b[i] == 0x55 && b[i+1] == 0xAA           
        ret.push(b[i..s-1]) # push last msg to list
        b = b[(0..i-1)]   # write the rest back to b
      end
      i -= 1
    end
    ret.push(b)
    return ret
  end

  # send a string payload (needs to be a valid json string)
  def send(payload)
    print("NSP: Sent =", payload)
    var payload_bin = self.encode(payload)
    self.ser.write(payload_bin)
    # print("NSP: Sent =", payload)
    log("NSP: NSPanel payload sent = " + str(payload_bin), 3)
  end

  # send a nextion payload
  def encodenx(payload)
    var b = bytes().fromstring(payload)
    b += bytes('FFFFFF')
    return b
  end

  def sendnx(payload)
    var payload_bin = self.encodenx(payload)
    self.ser.write(payload_bin)
    # print("NSP: Sent =", payload_bin)
    log("NSP: Nextion command sent = " + str(payload_bin), 3)
  end

  # sets time and date according to Tasmota local time
  def set_clock()
    var now = tasmota.rtc()
    var time_raw = now['local']
    var nsp_time = tasmota.time_dump(time_raw)
    var time_payload = '{"year":' + str(nsp_time['year']) + ',"mon":' + str(nsp_time['month']) + ',"day":' + str(nsp_time['day']) + ',"hour":' + str(nsp_time['hour']) + ',"min":' + str(nsp_time['min']) + ',"week":' + str(nsp_time['weekday']) + '}'
    log('NSP: Time and date synced with ' + time_payload, 3)
    self.send(time_payload)
  end

  # sync main screen power bars with tasmota POWER status
  def set_power()
    var ps = tasmota.get_power()
    for i:0..1
      if ps[i] == true
        ps[i] = "on"
      else 
        ps[i] = "off"
      end
    end
    var json_payload = '{\"switches\":[{\"outlet\":0,\"switch\":\"' + ps[0] + '\"},{\"outlet\":1,\"switch\":\"' + ps[1] +  '\"}]}'
    log('NSP: Switch state updated with ' + json_payload)
    self.send(json_payload)
  end  

  # commands to populate an empty screen, should be executed when screen initializes
  def screeninit()
    # self.send('{"queryInfo":"version"}')
    self.send('{"HMI_ATCDevice":{"ctype":"device","id":"' + self.atc['id'] + '","outlet":' + self.atc['outlet'] + ',"etype":"' + self.atc['etype'] + '"}')
    self.send('{"relation":[{"ctype":"device","id":"panel","name":"' + devicename + '","online":true}]}')
    self.send('{"HMI_dimOpen":' + persist.dim + '}')
    self.set_clock()
    self.set_power()
    tasmota.cmd("State")
    tasmota.cmd("TelePeriod")
  end

  # read serial port and decode messages according to protocol used
  def every_100ms()
    if self.ser.available() > 0
    var msg = self.ser.read()   # read bytes from serial as bytes
    import string
      if size(msg) > 0
        print("NSP: Received Raw =", msg)
        if msg[0..1] == self.header
          mode = "NSPanel"
          var lst = self.split_55(msg)
          for i:0..size(lst)-1
            msg = lst[i]
              if self.atc['mirror'] == true
                if msg[2] == 0x84 self.ser.write(msg)   # resend messages with type 0x84 for thermostat page
                end
              end
            var j = size(msg) - 1
            while msg[j] != 0x7D
              msg = msg[0..-1]
              j -= 1
            end        
            msg = msg[5..j]
              if size(msg) > 2
                if msg == bytes('7B226572726F72223A307D') # don't publish {"error":0}
                else 
                var jm = string.format("{\"NSPanel\":%s}",msg.asstring())
                tasmota.publish_result(jm, "RESULT")
                end
              end
          end
        elif msg == bytes('000000FFFFFF88FFFFFF')
          log("NSP: Screen Initialized")   # print the message as string
          self.screeninit()
        else
          var jm = string.format("{\"NSPanel\":{\"Nextion\":\"%s\"}}",str(msg[0..-4]))
          tasmota.publish_result(jm, "RESULT")        end       
      end
    end
  end
end      

nsp=NSPanel()

tasmota.add_rule("power1#state", /-> nsp.set_power())
tasmota.add_rule("power2#state", /-> nsp.set_power())

# add NSPSend command to Tasmota
def nspsend(cmd, idx, payload, payload_json)
  # NSPSend2 sends Nextion commands
  if idx == 2
  var command = nsp.sendnx(payload)
  tasmota.resp_cmnd_done()
  # NSPSend sends NSPanel commands, requires valid payload
  else
  import json
  var command = nsp.send(json.dump(payload_json))
  tasmota.resp_cmnd_done()
  end
end

tasmota.add_cmd('NSPSend', nspsend)

# add NSPMode command to Tasmota
def modeselect(NSPMode, idx, payload)
  if payload == "1"
    nsp.sendnx('DRAKJHSUYDGBNCJHGJKSHBDN')
    tasmota.resp_cmnd_done()
    mode = "Nextion"
  elif payload == "0"
    nsp.sendnx('recmod=1')
    nsp.sendnx('recmod=1')
    mode = "NSPanel"
    tasmota.resp_cmnd_done()
  else
  tasmota.resp_cmnd_str('{"Mode":"' + mode + '"}')
  end
end

tasmota.add_cmd('NSPMode', modeselect)

# add NSPDim command to Tasmota
def dimopen(NSPDim, idx, payload)
  if payload == "0" || payload == "1"
    persist.dim = payload
    nsp.send('{"HMI_dimOpen":' + payload + '}')
    tasmota.resp_cmnd_done()
  else
    payload = str(persist.dim)
  end
  import string
  var jm = string.format("{\"NSPanel\":{\"Energy-saving\":%s}}",payload)
  tasmota.publish_result(jm, "RESULT")
end

tasmota.add_cmd('NSPDim', dimopen)

# set wifi icon status

def set_wifi(value)
  var rssi = (value-1)/20
  rssi = '{"wifiState":"connected","rssiLevel":' + str(rssi) + '}'
  log('NSP: Wi-Fi icon set with ' + rssi, 3)
  nsp.send(rssi)
end

def set_disconnect()
  nsp.send('{"wifiState":"nonetwork","rssiLevel":0}')
end

tasmota.cmd("Rule3 1") # needed until Berry bug fixed
tasmota.cmd("State")
tasmota.add_rule("Time#Minute", /-> nsp.set_clock()) # set rule to update clock every minute
tasmota.add_rule("Tele#Wifi#RSSI", set_wifi) # set rule to update wifi icon
tasmota.add_rule("wifi#disconnected", set_disconnect) # set rule to change wifi icon on disconnect
tasmota.add_rule("mqtt#disconnected", set_disconnect) # set rule to change wifi icon on disconnect
tasmota.add_rule("system#boot", /-> nsp.screeninit()) 

tasmota.cmd("TelePeriod")
