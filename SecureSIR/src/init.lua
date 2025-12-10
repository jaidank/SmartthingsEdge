-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local TEMPERATURE = "temperature"
local SCHEDULE_EXPIRY = "schedule_expiry"

local capabilities = require "st.capabilities"
local log = require "log"

local utils = require "st.utils"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.CommandClass.Basic
local Basic = (require "st.zwave.CommandClass.Basic")({ version = 1 })
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 1 })
--- @type st.zwave.CommandClass.SwitchBinary
local SwitchBinary = (require "st.zwave.CommandClass.SwitchBinary")({ version = 2 })
--- @type st.zwave.CommandClass.Schedule
local Schedule = (require "st.zwave.CommandClass.Schedule")({version=4,strict=true})
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({ version = 1 })


local SECURE_SIR321_FINGERPRINTS = {
  {mfr = 0x0059, prod = 0x0010, model = 0x0001}, -- Secure SIR321
  {mfr = 0x0059, prod = 0x0010, model = 0x0002}, -- Secure SIR321
  {mfr = 0x0059, prod = 0x0010, model = 0x0003}, -- Secure SIR321
}

--- Determine whether the passed device is Aeon smart strip
---
--- @param driver Driver driver instance
--- @param device Device device isntance
--- @return boolean true if the device proper, else false
local function can_handle_secure_sir321(opts, driver, device, ...)
  for _, fingerprint in ipairs(SECURE_SIR321_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
      return true
    end
  end
  return false
end

local function basic_set_handler(self, device, cmd)
  log.info("basic_set_handler", cmd)
  if cmd.args.value == 0xFF then
    device:emit_event(capabilities.switch.switch.on())
  else
    device:emit_event(capabilities.switch.switch.off())
  end
end

local function basic_report_handler(self, device, cmd)
  log.info("basic_report_handler", cmd)
end

local function basic_get_handler(self, device, cmd)
  log.info("basic_get_handler", cmd)
  local is_on = device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME)
  device:send(Basic:Report({value = is_on == "on" and 0xff or 0x00}))
end

local function switch_on_handler(driver, device)
  log.info("switch_on_handler")
  device:send(Basic:Set({value = 0xff}))
  device:emit_event(capabilities.switch.switch.on())
  device:set_field(SCHEDULE_EXPIRY, nil)
end

local function switch_off_handler(driver, device)
  log.info("switch_off_handler")
  device:send(Basic:Set({value = 0x00}))
  device:emit_event(capabilities.switch.switch.off())
  device:set_field(SCHEDULE_EXPIRY, nil)
end

local function temperature_report_handler(self, device, cmd)
  log.info("temperature_report_handler")
  local cached_schedule_expiry = device:get_field(SCHEDULE_EXPIRY)

  if (cmd.args.sensor_type == SensorMultilevel.sensor_type.TEMPERATURE)
  then
    local scale = 'C'
    local sensor_value = cmd.args.sensor_value
    if (cmd.args.scale == SensorMultilevel.scale.temperature.FAHRENHEIT) then scale = 'F' end
    log.info("emit_component_event WaterTemperature")
    local evt = capabilities.temperatureMeasurement.temperature({value=sensor_value,unit=scale})
    device:emit_component_event(device.profile.components['WaterTemperature'],evt)
  end
  
  log.info("temperature_report_handler: do a Basic:Get")
  device:send(Basic:Get({}))

  if cached_schedule_expiry ~= nil and cached_schedule_expiry < os.time()
  then
	 log.info("temperature_report_handler schedule has expired")
     device:set_field(SCHEDULE_EXPIRY, nil)
     device:emit_event(capabilities.switch.switch.off())
  end
  
  log.info("temperature_report_handler done")
end

local function schedule_command_report(driver,device,cmd)
  local event
  local duration_byte = cmd.args.duration_byte
  log.info("schedule_command_report: ", duration_byte)
  
  if duration_byte == 0 then
    log.info("schedule_command_report - off")
    device:set_field(SCHEDULE_EXPIRY, nil)
    event = capabilities.switch.switch.off()
  else
    log.info("schedule_command_report - on")
    device:set_field(SCHEDULE_EXPIRY, os.time() + duration_byte * 60)
    event = capabilities.switch.switch.on()
  end
  device:emit_event_for_endpoint(cmd.src_channel, event)
end

local function zwave_switch_binary_report_handler(self, device, cmd)
  log.info("binary_event_handler", cmd)
  local value = cmd.args.value and cmd.args.value or cmd.args.target_value
  local event = value == SwitchBinary.value.OFF_DISABLE and capabilities.switch.switch.off() or capabilities.switch.switch.on()
  if cmd.src_channel == 0 then
    log.info("binary_event_handler emit_event_for_endpoint:", cmd.src_channel, "event:", event)
    device:emit_event_for_endpoint(cmd.src_channel, event)
    for ep = 1,4 do
      log.info("binary_event_handler emit_event_for_endpoint:", ep, "event:", event)
      device:emit_event_for_endpoint(ep, event)
    end
  else
    log.info("binary_event_handler emit_event_for_endpoint:", cmd.src_channel, "event:", event)
    device:emit_event_for_endpoint(cmd.src_channel, event)
  end
end

local function do_configure(driver, device)
    log.info("do_configure: called: ", args)
end

local function update_preferences(self, device, event, args)
    log.info("update_preferences: called: ", args)

    if device.preferences.reportingInterval ~= nil and 
        args.old_st_store.preferences.reportingInterval ~= device.preferences.reportingInterval 
    then
        log.info("preferences: send reporting interval")
        device:send(Configuration:Set({parameter_number = 3, size = 2, configuration_value = device.preferences.reportingInterval}))
    end
    if device.preferences.deltaT ~= nil and
        args.old_st_store.preferences.deltaT ~= device.preferences.deltaT
    then
        log.info("preferences: send deltaT")
        device:send(Configuration:Set({parameter_number = 4, size = 2, configuration_value = device.preferences.deltaT}))
    end
    if device.preferences.temperatureCutoff ~= nil and
        args.old_st_store.preferences.temperatureCutoff ~= device.preferences.temperatureCutoff
    then
        log.info("preferences: send temperature cutoff")
        device:send(Configuration:Set({parameter_number = 5, size = 2, configuration_value = device.preferences.temperatureCutoff}))
    end
end

local function device_init(self, device, event)
    log.info("device_init", event)
    device:set_update_preferences_fn(update_preferences)
end

local function added_handler(self, device)
    log.info("added_handler")
    
    -- temperature scale
    centigrade = 0                                  -- centigrade
    device:send(Configuration:Set({parameter_number = 2, size = 2, configuration_value = centigrade}))

    -- initial reporting interval
    local interval_min = 600                        -- 10 minutes
    if device.preferences.interval ~= nil then
        interval_min = device.preferences.interval
    end
    device:send(Configuration:Set({parameter_number = 3, size = 2, configuration_value = interval_min}))

    -- initial deltaT
    local deltaT_min = 5                            -- 0.5 degrees
    if device.preferences.deltaT ~= nil then
        deltaT_min = device.preferences.deltaT
    end
    device:send(Configuration:Set({parameter_number = 4, size = 2, configuration_value = deltaT_min}))

    device:refresh()
end

local secure_sir321 = {
  NAME = "Secure SIR321 Switch",
  zwave_handlers = {
    [cc.BASIC] = {
      [Basic.SET] = basic_set_handler,
      [Basic.GET] = basic_get_handler,
      [Basic.REPORT] = basic_report_handler
    },
    [cc.SWITCH_BINARY] = {
      [SwitchBinary.REPORT] = zwave_switch_binary_report_handler
    },
    [cc.SCHEDULE] = {
      [Schedule.COMMAND_REPORT] = schedule_command_report,
    },
    [cc.SENSOR_MULTILEVEL] = {
        [SensorMultilevel.REPORT] = temperature_report_handler
    }
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    }  
  },
  lifecycle_handlers = {
      init = device_init,
      added = added_handler,
      driverSwitched = driver_switched,
      infoChanged = update_preferences,
      doConfigure = do_configure,
  },  
  can_handle = can_handle_secure_sir321,
}

local switch = ZwaveDriver("secure_sir321", secure_sir321)
-- log.info("secure_sir321 init.lua")
switch:run()
