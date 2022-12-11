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
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.CommandClass.Battery
local Battery = (require "st.zwave.CommandClass.Battery")({version=1})
--- @type st.zwave.CommandClass.SensorMultilevel
local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({version=1})
--- @type st.zwave.CommandClass.ThermostatMode
local ThermostatMode = (require "st.zwave.CommandClass.ThermostatMode")({version=3})
--- @type st.zwave.CommandClass.ThermostatSetpoint
local ThermostatSetpoint = (require "st.zwave.CommandClass.ThermostatSetpoint")({version=3})
--- @type st.zwave.CommandClass.Clock
local Clock = require "st.zwave.CommandClass.Clock"
local constants = require "st.zwave.constants"
local utils = require "st.utils"

local LATEST_BATTERY_REPORT_TIMESTAMP = "latest_battery_report_timestamp"
local LATEST_CLOCK_SET_TIMESTAMP = "latest_clock_set_timestamp"
local WEEK = {1, 2, 3, 4, 5, 6, 0}

local do_refresh = function(self, device)
  device:send(ThermostatMode:SupportedGet({}))
  device:send(ThermostatMode:Get({}))
  device:send(SensorMultilevel:Get({}))
  device:send(ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}))
  device:send(Battery:Get({}))
end

local function seconds_since_latest_clock_set(device)
    local last_clock_set_time = device:get_field(LATEST_CLOCK_SET_TIMESTAMP)
    if last_clock_set_time ~= nil then
        return os.difftime(os.time(), last_clock_set_time)
    end
    return CLOCK_SET_INTERVAL_SEC + 1
end

local function check_and_send_battery_get(device)
    -- Check if time to request new battery report. one time a day
    if seconds_since_latest_battery_report(device) > BATTERY_REPORT_INTERVAL_SEC then
        device:send(Battery:Get({}))
    end
end

local function set_setpoint_factory(setpoint_type)
  return function(driver, device, command)
    local scale = device:get_field(constants.TEMPERATURE_SCALE)
    local value = convert_to_device_temp(command.args.setpoint, scale)

    local set = ThermostatSetpoint:Set({
      setpoint_type = setpoint_type,
      scale = scale,
      value = value
    })
    device:send_to_component(set, command.component)

    local follow_up_poll = function()
      device:send_to_component(ThermostatSetpoint:Get({setpoint_type = setpoint_type}), command.component)
    end

    device.thread:call_with_delay(1, follow_up_poll)
  end
end

local function cmdClockSet()
    local now = os.date("*t") -- UTC
    log.info("ClockSet: ".. now.hour ..":" .. now.min ..":" .. WEEK[now.wday])  -- lua wday starts from Sunday(0).
    return Clock:Set({hour=now.hour, minute=now.min, weekday=WEEK[now.wday]})
end

local function check_and_send_clock_set(device)
    -- Update device clock time, one time a day
    if seconds_since_latest_clock_set(device) > CLOCK_SET_INTERVAL_SEC then
        device:send(cmdClockSet())
        device:set_field(LATEST_CLOCK_SET_TIMESTAMP, os.time())
    end
end

local function check_and_send_cached_setpoint(device)
    local cached_setpoint_command = device:get_field(CACHED_SETPOINT)

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

local driver_template = {
  supported_capabilities = {
    capabilities.temperatureMeasurement,
    capabilities.thermostatHeatingSetpoint,
    capabilities.thermostatMode,
    capabilities.battery,
    capabilities.powerMeter,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    },
    [capabilities.thermostatHeatingSetpoint.ID] = {
      [capabilities.thermostatHeatingSetpoint.commands.setHeatingSetpoint.NAME] = set_setpoint_factory(ThermostatSetpoint.setpoint_type.HEATING_1)
    }
  },
  sub_drivers = {
    require("everspring-radiator-thermostat"),
  }
}

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
--- @type st.zwave.Driver
local thermostat = ZwaveDriver("zwave_thermostat", driver_template)
thermostat:run()
