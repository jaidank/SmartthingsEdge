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

local capabilities = require "st.capabilities"
local utils = require "st.utils"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.CommandClass.Basic
local WakeUp = (require "st.zwave.CommandClass.Basic")({version=1})
--- @type st.zwave.CommandClass.WakeUp
local WakeUp = (require "st.zwave.CommandClass.WakeUp")({version=2})
--- @type st.zwave.CommandClass.ThermostatMode
local ThermostatMode = (require "st.zwave.CommandClass.ThermostatMode")({version=3})
--- @type st.zwave.CommandClass.ThermostatSetpoint
local ThermostatSetpoint = (require "st.zwave.CommandClass.ThermostatSetpoint")({version=3})
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({version=4})
--- @type st.zwave.CommandClass.Battery
local Battery = (require "st.zwave.CommandClass.Battery")({version=1})
local log = require "log"


local LATEST_WAKEUP = "latest_wakeup"
local CACHED_SETPOINT = "cached_setpoint"
local STELLAZ_WAKEUP_INTERVAL = 3600 --seconds (an hour)
local STELLAZ_DEFAULT_SETPOINT = 13 --degrees C 
local GET_BATTERY = "get_battery"

local EUROTRONIC_STELLAZ_FINGERPRINTS = {
    { manufacturerId = 0x0148, productType = 0x0001, productId = 0x0001 } -- EUROtronic StellaZ TRV
}

local function can_handle_eurotronic_stellaz(opts, driver, device, cmd, ...)
    log.info("can_handle_eurotronic_stellaz")
    for _, fingerprint in ipairs(EUROTRONIC_STELLAZ_FINGERPRINTS) do
        if device:id_match( fingerprint.manufacturerId, fingerprint.productType, fingerprint.productId)
        then
            log.info("can_handle_eurotronic_stellaz HIT productId: ", fingerprint.productId)
            return true
        end
    end

    log.info("can_handle_eurotronic_stellaz MISS productId: ", fingerprint.productId)

    return false
end

local function get_latest_wakeup_timestamp(device)
  return device:get_field(LATEST_WAKEUP)
end

local function set_latest_wakeup_timestamp(device)
  device:set_field(LATEST_WAKEUP, os.time())
end

local function seconds_since_latest_wakeup(device)
  local latest_wakeup = get_latest_wakeup_timestamp(device)
  if latest_wakeup ~= nil then
    return os.difftime(os.time(), latest_wakeup)
  else
    return 0
  end
end

-- StellaZ is a sleepy device, therefore it won't accept setpoint commands rightaway.
-- That's why driver waits for a device to wake up and then sends cached setpoint command.
-- Driver assumes that wakeUps come in reguraly every hour???
local function wakeup_notification_handler(self, device, cmd)
  local version = require "version"

  log.info("eurotronic_stellaz wakeup: started")

  local battery = device:get_field(GET_BATTERY)
  local setpoint = device:get_field(CACHED_SETPOINT)

  if battery == nil then
    battery = 23
  end

  if setpoint ~= nil then
    log.info("eurotronic_stellaz wakeup: sending setpoint")
    device:send(setpoint)
    -- device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}))
    device:set_field(CACHED_SETPOINT, nil)
  else
    if battery >= 23
    then
      log.info("eurotronic_stellaz wakeup: sending battery request")
      device:send(Battery:Get({}))
      battery = 0
    end
  end

  battery = battery + 1
  device:set_field(GET_BATTERY, battery)

  log.info("eurotronic_stellaz wakeup: sending temperature request")
  device:send(SensorMultilevel:Get({}))	-- Get latest temperature

  log.info("eurotronic_stellaz wakeup: started")
end

local function set_heating_setpoint(driver, device, command)
  local scale = ThermostatSetpoint.scale.CELSIUS
  local value = command.args.setpoint

  if (value >= 40) then -- assume this is a fahrenheit value
    value = utils.f_to_c(value)
  end
  local set = ThermostatSetpoint:Set({
    setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1,
    scale = scale,
    value = value
  })
  device:set_field(CACHED_SETPOINT, set)

  device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = value, unit = 'C' }))
end

local function temperature_report_handler(self, device, cmd)
    log.info("temperature_report_handler: started")

    local scale = 'C'
    local sensor_value = cmd.args.sensor_value
    log.info("temperature_report_handler cmd.src_channel: ", cmd.src_channel, 
             " sensor_value: ", sensor_value)
    device:emit_event_for_endpoint(cmd.src_channel, capabilities.temperatureMeasurement.temperature({value = sensor_value, unit = scale}))

    log.info("temperature_report_handler: ended")
end

local function battery_report_handler(self, device, cmd)
    log.info("battery_report_handler: started")

    local battery_level = cmd.args.battery_level
    log.info("battery_report_handler: ", battery_level)

    device:emit_event(capabilities.battery.battery(battery_level))

    log.info("battery_report_handler: ended")
end

local function update_preference(self, device, args)
    if device.preferences.reportingInterval ~= nil and
        args.old_st_store.preferences.reportingInterval ~= device.preferences.reportingInterval
    then
        log.info("preferences: send wakeup")
        device:send(WakeUp:IntervalSet({node_id = self.environment_info.hub_zwave_id, seconds = device.preferences.reportingInterval}))
    end
end

local function device_init(self, device)
    log.info("device_init: started")

    -- update preferences function
    device:set_update_preferences_fn(update_preference)

    -- set Thermostat Setpoint to default
    local setpoint = ThermostatSetpoint:Set({
                         setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1,
                         scale = ThermostatSetpoint.scale.CELSIUS,
                         value = STELLAZ_DEFAULT_SETPOINT})
    device:send(setpoint)
    log.info("device_init: default setpoint sent")

    log.info("device_init: emit setpoint event")
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = STELLAZ_DEFAULT_SETPOINT, unit = 'C' }))

    log.info("device_init: initialise battery report")
    device:set_field(GET_BATTERY, 23)

    log.info("device_init: ended")
end

local function driver_switched(self, device)
    log.info("driver_switched: started")

    log.info("driver_switched: initialise battery report")
    device:set_field(GET_BATTERY, 23)

    log.info("driver_switched: ended")
end 

local function added_handler(self, device)
    log.info("added_handler: started")

    log.info("added_handler: initialise battery report")
    device:set_field(GET_BATTERY, 23)

    log.info("added_handler: set WakeUp")
    device:send(WakeUp:IntervalSet({node_id = self.environment_info.hub_zwave_id, 
                                   seconds = STELLAZ_WAKEUP_INTERVAL}))

    -- set ThermostatMode to Energy Saving here

    log.info("added_handler: ended")
end

local function do_refresh(self, device)
    log.info("do_refresh: started")

    log.info("do_refresh: initialise battery report")
    device:set_field(GET_BATTERY, 23)

    log.info("do_refresh: ended")
end

local stellaz_radiator_thermostat = {
  NAME = "stellaz radiator thermostat",
  zwave_handlers = {
    [cc.BATTERY] = {
        [Battery.REPORT] = battery_report_handler
    },
    [cc.WAKE_UP] = {
        [WakeUp.NOTIFICATION] = wakeup_notification_handler
    },
    [cc.SENSOR_MULTILEVEL] = {
        [SensorMultilevel.REPORT] = temperature_report_handler
    }
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
        [capabilities.refresh.commands.refresh.NAME] = do_refresh
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
        [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_setpoint
    }
  },
  lifecycle_handlers = {
    init = device_init,
    added = added_handler,
    driverSwitched = driver_switched
  },
  can_handle = can_handle_stellaz_radiator_thermostat
}

log.info("stellaz init.lua: ZwaveDriver()")
local stellaz = ZwaveDriver("stellaz_radiator_thermostat", stellaz_radiator_thermostat)

log.info("stellaz init.lua: run()")
stellaz:run()

