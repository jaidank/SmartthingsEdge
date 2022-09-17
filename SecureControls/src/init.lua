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

-- Aidan started Secure SRT modifications: + SensorMultilevel + ThermostatOperatingState - Clock - Protection

local capabilities = require "st.capabilities"
local utils = require "st.utils"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({ version = 5 })
--- @type st.zwave.CommandClass.ThermostatSetpoint
local ThermostatSetpoint = (require "st.zwave.CommandClass.ThermostatSetpoint")({ version = 1 })
--- @type st.zwave.CommandClass.WakeUp
local WakeUp = (require "st.zwave.CommandClass.WakeUp")({version=2})
--- @type st.zwave.CommandClass.Battery
local Battery = (require "st.zwave.CommandClass.Battery")({version=1})
--- @type st.zwave.CommandClass.ThermostatOperatingState
local ThermostatOperatingState = (require "st.zwave.CommandClass.ThermostatOperatingState")({ version = 1 })
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({version=1})
local log = require "log"

local constants = (require "st.zwave.constants")
local DEVICE_WAKEUP_INTERVAL = 10 * 60
local LATEST_BATTERY_REPORT_TIMESTAMP = "latest_battery_report_timestamp"
local CACHED_SETPOINT = "cached_setpoint"
local BATTERY_REPORT_INTERVAL_SEC = 3 * 60 * 60  -- every 3 hours (was once a day)
local DELAY_TO_GET_UPDATED_VALUE = 1
local CLAMP = {
    FAHRENHEIT_MIN = 39,
    FAHRENHEIT_MAX = 82,
    CELSIUS_MIN = 4,
    CELSIUS_MAX = 28
}
local STATE = "state"

local SECURE_SRT_THERMOSTAT_FINGERPRINTS = {
    { manufacturerId = 0x0059, productType = 0x0001, productId = 0x0004 }, -- Secure SRT323 Thermostat (spec)
    { manufacturerId = 0x0000, productType = 0x0000, productId = 0x0000 }, -- Secure SRT323 Thermostat (reported)
    { manufacturerId = 0x0059, productType = 0x0001, productId = 0x0003 }  -- Secure SRT321 Thermostat
}

--[[ TODO Add Secure SRT information (which can report its local temperature to the Z-Wave network).
     Add handler for SRT321 Switch Binary 0x25 (instead of ThermostatOperatingState
--]]

local function can_handle_secure_srt_thermostat(opts, driver, device, cmd, ...)
    log.info("can_handle_secure_srt_thermostat")
    for _, fingerprint in ipairs(SECURE_SRT_THERMOSTAT_FINGERPRINTS) do
        if device:id_match( fingerprint.manufacturerId, fingerprint.productType, fingerprint.productId) then
            log.info("can_handle_secure_srt_thermostat: hit")
            return true
        end
    end

    log.info("can_handle_secure_srt_thermostat: miss")
    return false
end

local function adjust_temperature_if_exceeded_min_max_limit (degree, scale)
    if scale == ThermostatSetpoint.scale.CELSIUS then
        return utils.clamp_value(degree, CLAMP.CELSIUS_MIN, CLAMP.CELSIUS_MAX)
    else
        return utils.clamp_value(degree, CLAMP.FAHRENHEIT_MIN, CLAMP.FAHRENHEIT_MAX)
    end
end

local function seconds_since_latest_battery_report(device)
    local last_time = device:get_field(LATEST_BATTERY_REPORT_TIMESTAMP)
    if last_time ~= nil then
        return os.difftime(os.time(), last_time)
    end
    return BATTERY_REPORT_INTERVAL_SEC + 100
end

local function check_and_send_battery_get(device)
    log.info("check_and_send_battery_get")
    -- Check if time to request new battery report. one time a day
    if seconds_since_latest_battery_report(device) > BATTERY_REPORT_INTERVAL_SEC then
        device:send(Battery:Get({}))
    end
end

local function check_and_send_cached_setpoint(device)
    local cached_setpoint_command = device:get_field(CACHED_SETPOINT)
    log.info("check_and_send_cached_setpoint")

    if cached_setpoint_command ~= nil then
        device:send(cached_setpoint_command)
        local follow_up_poll = function()
            device:send(
                    ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1})
            )
        end
        device.thread:call_with_delay(DELAY_TO_GET_UPDATED_VALUE, follow_up_poll)
    end
end

local function compare_setpoint(value1, scale1, value2, scale2)
    if scale1 ~= scale2 then
        if scale1 == ThermostatSetpoint.scale.FAHRENHEIT then
            value1 = utils.f_to_c(value1)
        else
            value2 = utils.f_to_c(value2)
        end
    end

    return value1 == value2
end

local function thermostat_setpoint_report_handler(self, device, cmd)
    local cached_setpoint = device:get_field(CACHED_SETPOINT)
    log.info("thermostat_setpoint_report_handler")
    if cached_setpoint ~= nil then
        if compare_setpoint(cmd.args.value, cmd.args.scale, cached_setpoint.args.value, cached_setpoint.args.scale) then
            device:set_field(CACHED_SETPOINT, nil)
        else
            log.info("resent cached setpoint command")
            return check_and_send_cached_setpoint(device)
        end
    end

    if (cmd.args.setpoint_type == ThermostatSetpoint.setpoint_type.HEATING_1) then
        local heatValue = adjust_temperature_if_exceeded_min_max_limit(cmd.args.value, cmd.args.scale)
        local unitValue = cmd.args.scale == ThermostatSetpoint.scale.FAHRENHEIT and 'F' or 'C'

        device:set_field(constants.TEMPERATURE_SCALE, cmd.args.scale, {persist = true})
        device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = heatValue, unit = unitValue }))
    end
end

-- placeholder for switch binary handler (srt321)
local function switch_binary_report_handler(self, device, cmd)
  local event = nil

end

-- just guessing that the two states are IDLE and HEATING
local function operating_state_report_handler(self, device, cmd)
  local event = nil
  local state = cmd.args.operating_state

  log.info("operating_state_report_handler state: ", state)

  if state == 0 then  -- IDLE
    log.info("operating_state_report_handler - IDLE")
    event = capabilities.thermostatOperatingState.thermostatOperatingState.idle()
  elseif state == 1 then  -- HEATING
    log.info("operating_state_report_handler - HEATING")
    event = capabilities.thermostatOperatingState.thermostatOperatingState.heating()
  else
    log.info("operating_state_report_handler - UNKNOWN -> IDLE")
    event = capabilities.thermostatOperatingState.thermostatOperatingState.idle()
  end

  log.info("operating_state_report_handler - ready to set_field")
  device:set_field(STATE, state, {persist = true})

  log.info("operating_state_report_handler event: ", event)

  if (event ~= nil) then
    log.info("operating_state_report_handler event: ", event)
    device:emit_event(event)
  end
end

local function temperature_report_handler(self, device, cmd)
  log.info("temperature_report_handler")
  if (cmd.args.sensor_type == SensorMultilevel.sensor_type.TEMPERATURE) then
    local scale = 'C'
    if (cmd.args.scale == SensorMultilevel.scale.temperature.FAHRENHEIT) then scale = 'F' end
    device:emit_event_for_endpoint(cmd.src_channel, capabilities.temperatureMeasurement.temperature({value = cmd.args.sensor_value, unit = scale}))
    device:set_field(TEMPERATURE, cmd.args.sensor_value, {persist = true})
  end
end

local function battery_report_handler(self, device, cmd)
    local battery_level = cmd.args.battery_level
    log.info("battery_report_handler: ", battery_level)
    if (battery_level == Battery.battery_level.BATTERY_LOW_WARNING) then
        battery_level = 2
    end

    if battery_level > 100 then
        log.error("Z-Wave battery report handler: invalid battery level " .. battery_level)
    else
        device:emit_event(capabilities.battery.battery(battery_level))
    end

    device:set_field(LATEST_BATTERY_REPORT_TIMESTAMP, os.time())
end

--TODO: Update this once we've decided how to handle setpoint commands
local function convert_to_device_temp(command_temp, device_scale)
    -- capability comes with CELSIUS scale by default, but not sure all the time
    -- under 40, assume celsius
    if (command_temp < 40 and device_scale == ThermostatSetpoint.scale.FAHRENHEIT) then
        command_temp = utils.c_to_f(command_temp)
    elseif (command_temp >= 40 and (device_scale == ThermostatSetpoint.scale.CELSIUS or device_scale == nil)) then
        command_temp = utils.f_to_c(command_temp)
    end
    return command_temp
end

local function set_heating_setpoint(driver, device, command)
    local device_scale = device:get_field(constants.TEMPERATURE_SCALE)
    if device_scale == nil then
        device_scale = ThermostatSetpoint.scale.CELSIUS
    end
    local value = convert_to_device_temp(command.args.setpoint, device_scale)

    local setCommand = ThermostatSetpoint:Set({
        setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1,
        scale = device_scale,
        value = adjust_temperature_if_exceeded_min_max_limit(value, device_scale)
    })

    local value_celsius = device_scale == ThermostatSetpoint.scale.CELSIUS and value or utils.f_to_c(value)
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = value_celsius, unit = 'C' }))
    device:send(setCommand)
    device:set_field(CACHED_SETPOINT, setCommand)
end

local function wakeup_notification_handler(self, device, cmd)
    log.info("wakeup_notification_handler")
    check_and_send_cached_setpoint(device)
    check_and_send_battery_get(device)
end

local function update_preference(self, device, args)
    if device.preferences.reportingInterval ~= nil and args.old_st_store.preferences.reportingInterval ~= device.preferences.reportingInterval then
        device:send(WakeUp:IntervalSet({node_id = self.environment_info.hub_zwave_id, seconds = device.preferences.reportingInterval*60}))
    end
end

local function device_init(self, device)
    log.info("device_init")
    device:set_update_preferences_fn(update_preference)
end

local function added_handler(self, device)
    log.info("added_handler")
    -- initial capability value
    device:emit_event(capabilities.thermostatHeatingSetpoint.heatingSetpoint({value = 20.0, unit = 'C' }))
    device:emit_event(capabilities.battery.battery(100))

    local interval_min = 5
    if device.preferences.reportingInterval ~= nil then
        interval_min = device.preferences.reportingInterval
    end
    device:send(WakeUp:IntervalSet({node_id = self.environment_info.hub_zwave_id, seconds = interval_min*60}))

    device:refresh()
end

local function do_refresh(self, device)
    log.info("do_refresh")
    device:send(Battery:Get({}))
    device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}))
end

local secure_srt_thermostat = {
    NAME = "secure_srt_thermostat",
    zwave_handlers = {
        [cc.BATTERY] = {
            [Battery.REPORT] = battery_report_handler
        },
        [cc.WAKE_UP] = {
            [WakeUp.NOTIFICATION] = wakeup_notification_handler
        },
        [cc.THERMOSTAT_SETPOINT] = {
            [ThermostatSetpoint.REPORT] = thermostat_setpoint_report_handler
        },
        [cc.THERMOSTAT_OPERATING_STATE] = {
            [ThermostatOperatingState.REPORT] = operating_state_report_handler
        },
        [cc.SENSOR_MULTILEVEL] = {
            [SensorMultilevel.REPORT] = temperature_report_handler
        }
    },
    capability_handlers = {
        [capabilities.refresh.ID] = {
            [capabilities.refresh.commands.refresh.NAME] = do_refresh,
        },
        [capabilities.thermostatHeatingSetpoint.ID] = {
            [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_heating_setpoint
        }
    },
    lifecycle_handlers = {
        init = device_init,
        added = added_handler,
    },
    can_handle = can_handle_secure_srt_thermostat
}

log.info("secure_srt_thermostat init.lua")

local thermostat = ZwaveDriver("secure_srt_thermostat", secure_srt_thermostat)
log.info("thermostat init.lua")
thermostat:run()

