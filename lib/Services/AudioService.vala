//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

namespace Plank
{
	public enum AudioTarget
	{
		OUTPUT,
		INPUT
	}

	public class AudioDevice : Object
	{
		public string id { get; private set; }
		public string name { get; private set; }

		public AudioDevice (string id, string name)
		{
			this.id = id;
			this.name = name;
		}
	}

	public class AudioService : Object
	{
		const uint ACTION_TIMEOUT_MS = 3000;
		const uint VOLUME_DEBOUNCE_MS = 80;
		const uint EVENT_DEBOUNCE_MS = 75;
		const uint FALLBACK_REFRESH_SECONDS = 10;

		static AudioService? instance;

		public static unowned AudioService get_default ()
		{
			if (instance == null)
				instance = new AudioService ();
			return instance;
		}

		public bool output_available { get; private set; default = false; }
		public double output_volume { get; private set; default = 0.0; }
		public bool output_muted { get; private set; default = false; }
		public bool input_available { get; private set; default = false; }
		public double input_volume { get; private set; default = 0.0; }
		public bool input_muted { get; private set; default = false; }
		public string default_output { get; private set; default = ""; }
		public string default_input { get; private set; default = ""; }

		public signal void state_changed ();
		public signal void devices_changed ();

		CommandRunner runner;
		Cancellable lifetime;
		Gee.ArrayList<AudioDevice> outputs;
		Gee.ArrayList<AudioDevice> inputs;
		Subprocess? event_monitor;
		uint event_refresh_id = 0U;
		bool event_devices_dirty = false;
		uint fallback_refresh_id = 0U;
		uint output_apply_id = 0U;
		uint input_apply_id = 0U;
		bool refresh_running = false;
		bool refresh_again = false;
		bool devices_refresh_running = false;
		bool devices_refresh_again = false;
		bool output_dirty = false;
		bool input_dirty = false;
		bool output_apply_running = false;
		bool input_apply_running = false;

		AudioService ()
		{
			runner = new CommandRunner ();
			lifetime = new Cancellable ();
			outputs = new Gee.ArrayList<AudioDevice> ();
			inputs = new Gee.ArrayList<AudioDevice> ();
			refresh.begin ();
			start_event_monitor ();
		}

		~AudioService ()
		{
			lifetime.cancel ();
			if (event_monitor != null)
				event_monitor.force_exit ();
			remove_source (ref event_refresh_id);
			remove_source (ref fallback_refresh_id);
			remove_source (ref output_apply_id);
			remove_source (ref input_apply_id);
		}

		public unowned Gee.ArrayList<AudioDevice> get_devices (AudioTarget target)
		{
			return target == AudioTarget.OUTPUT ? outputs : inputs;
		}

		public bool is_available (AudioTarget target)
		{
			return target == AudioTarget.OUTPUT ? output_available : input_available;
		}

		public double get_volume (AudioTarget target)
		{
			return target == AudioTarget.OUTPUT ? output_volume : input_volume;
		}

		public bool is_muted (AudioTarget target)
		{
			return target == AudioTarget.OUTPUT ? output_muted : input_muted;
		}

		public string get_default_device (AudioTarget target)
		{
			return target == AudioTarget.OUTPUT ? default_output : default_input;
		}

		public async void refresh ()
		{
			if (refresh_running) {
				refresh_again = true;
				return;
			}
			refresh_running = true;
			do {
				refresh_again = false;
				yield refresh_target (AudioTarget.OUTPUT);
				yield refresh_target (AudioTarget.INPUT);
			} while (refresh_again && !lifetime.is_cancelled ());
			refresh_running = false;
		}

		async void refresh_target (AudioTarget target)
		{
			try {
				var result = yield runner.run ({ "wpctl", "get-volume", target_name (target) },
					null, ACTION_TIMEOUT_MS, lifetime);
				double volume = 0.0;
				bool muted = false;
				var available = result.successful
					&& parse_volume_output (result.standard_output, out volume, out muted);
				if (!available) {
					volume = 0.0;
					muted = false;
				}
				if (!is_dirty (target) && !is_apply_running (target))
					set_state (target, available, volume, muted);
			} catch (Error e) {
				if (!lifetime.is_cancelled ())
					set_state (target, false, 0.0, false);
			}
		}

		public void set_volume (AudioTarget target, double volume)
		{
			var maximum = target == AudioTarget.OUTPUT ? 1.5 : 1.0;
			volume = double.max (0.0, double.min (maximum, volume));
			set_state (target, true, volume, is_muted (target));
			if (target == AudioTarget.OUTPUT) {
				output_dirty = true;
				remove_source (ref output_apply_id);
				output_apply_id = Timeout.add (VOLUME_DEBOUNCE_MS, () => {
					output_apply_id = 0U;
					apply_pending_volume.begin (AudioTarget.OUTPUT);
					return false;
				});
			} else {
				input_dirty = true;
				remove_source (ref input_apply_id);
				input_apply_id = Timeout.add (VOLUME_DEBOUNCE_MS, () => {
					input_apply_id = 0U;
					apply_pending_volume.begin (AudioTarget.INPUT);
					return false;
				});
			}
		}

		public void adjust_volume (AudioTarget target, double delta, double maximum = 1.0)
		{
			set_volume (target, double.min (maximum, get_volume (target) + delta));
		}

		async void apply_pending_volume (AudioTarget target)
		{
			if (is_apply_running (target))
				return;
			set_apply_running (target, true);
			while (is_dirty (target) && !lifetime.is_cancelled ()) {
				set_dirty (target, false);
				var percent = (int) Math.round (get_volume (target) * 100.0);
				try {
					yield runner.run ({ "wpctl", "set-volume", target_name (target),
						"%d%%".printf (percent) }, null, ACTION_TIMEOUT_MS, lifetime);
				} catch (Error e) {
					if (!lifetime.is_cancelled ())
						warning ("Unable to set audio volume: %s", e.message);
				}
			}
			set_apply_running (target, false);
			refresh.begin ();
		}

		public async void set_muted (AudioTarget target, bool muted)
		{
			set_state (target, true, get_volume (target), muted);
			try {
				yield runner.run ({ "wpctl", "set-mute", target_name (target), muted ? "1" : "0" },
					null, ACTION_TIMEOUT_MS, lifetime);
			} catch (Error e) {
				if (!lifetime.is_cancelled ())
					warning ("Unable to change audio mute state: %s", e.message);
			}
			refresh.begin ();
		}

		public async void refresh_devices ()
		{
			if (devices_refresh_running) {
				devices_refresh_again = true;
				return;
			}
			devices_refresh_running = true;
			do {
				devices_refresh_again = false;
				yield refresh_device_target (AudioTarget.OUTPUT);
				yield refresh_device_target (AudioTarget.INPUT);
			} while (devices_refresh_again && !lifetime.is_cancelled ());
			devices_refresh_running = false;
			devices_changed ();
		}

		async void refresh_device_target (AudioTarget target)
		{
			try {
				var default_result = yield runner.run ({ "pactl", target == AudioTarget.OUTPUT
					? "get-default-sink" : "get-default-source" }, null, ACTION_TIMEOUT_MS, lifetime);
				var list_result = yield runner.run ({ "pactl", "list", "short",
					target == AudioTarget.OUTPUT ? "sinks" : "sources" }, null, ACTION_TIMEOUT_MS, lifetime);
				var devices = target == AudioTarget.OUTPUT ? outputs : inputs;
				devices.clear ();
				if (list_result.successful) {
					foreach (unowned string line in list_result.standard_output.split ("\n")) {
						var fields = line.split ("\t");
						if (fields.length < 2 || (target == AudioTarget.INPUT && fields[1].has_suffix (".monitor")))
							continue;
						devices.add (new AudioDevice (fields[1], fields[1]));
					}
				}
				if (target == AudioTarget.OUTPUT)
					default_output = default_result.successful ? default_result.standard_output.strip () : "";
				else
					default_input = default_result.successful ? default_result.standard_output.strip () : "";
			} catch (Error e) {
				if (!lifetime.is_cancelled ())
					warning ("Unable to refresh audio devices: %s", e.message);
			}
		}

		public async void set_default_device (AudioTarget target, string device)
		{
			try {
				var source = target == AudioTarget.INPUT;
				var default_result = yield runner.run ({ "pactl",
					source ? "set-default-source" : "set-default-sink", device },
					null, ACTION_TIMEOUT_MS, lifetime);
				if (!default_result.successful) {
					warning ("Unable to change the default audio device: %s",
						default_result.standard_error.strip ());
					refresh_devices.begin ();
					return;
				}
				var streams = yield runner.run ({ "pactl", "list", "short",
					source ? "source-outputs" : "sink-inputs" }, null, ACTION_TIMEOUT_MS, lifetime);
				if (streams.successful) {
					foreach (unowned string line in streams.standard_output.split ("\n")) {
						var fields = line.split ("\t");
						if (fields.length < 1 || fields[0] == "")
							continue;
						yield runner.run ({ "pactl", source ? "move-source-output" : "move-sink-input",
							fields[0], device }, null, ACTION_TIMEOUT_MS, lifetime);
					}
				}
			} catch (Error e) {
				if (!lifetime.is_cancelled ())
					warning ("Unable to change the default audio device: %s", e.message);
			}
			refresh_devices.begin ();
			refresh.begin ();
		}

		public static bool parse_volume_output (string output, out double volume, out bool muted)
		{
			volume = 0.0;
			muted = output.contains ("[MUTED]");
			var fields = output.strip ().split (" ");
			if (fields.length < 2 || fields[0] != "Volume:")
				return false;
			return double.try_parse (fields[1], out volume);
		}

		void start_event_monitor ()
		{
			if (Environment.find_program_in_path ("pactl") == null) {
				start_fallback_refresh ();
				return;
			}
			try {
				string[] monitor_argv;
				if (Environment.find_program_in_path ("setpriv") != null)
					monitor_argv = { "setpriv", "--pdeathsig", "TERM", "pactl", "subscribe" };
				else
					monitor_argv = { "pactl", "subscribe" };
				event_monitor = new Subprocess.newv (monitor_argv,
					SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
				var stream = new DataInputStream (event_monitor.get_stdout_pipe ());
				watch_events.begin (stream);
			} catch (Error e) {
				event_monitor = null;
				start_fallback_refresh ();
			}
		}

		async void watch_events (DataInputStream stream)
		{
			try {
				string? line;
				while ((line = yield stream.read_line_utf8_async (Priority.DEFAULT, lifetime)) != null) {
					if (line.contains ("sink") || line.contains ("source") || line.contains ("server")) {
						var devices_changed = line.contains ("'new'") || line.contains ("'remove'")
							|| line.contains ("server");
						schedule_event_refresh (devices_changed);
					}
				}
			} catch (Error e) {}
			if (!lifetime.is_cancelled ())
				start_fallback_refresh ();
		}

		void schedule_event_refresh (bool devices_changed)
		{
			event_devices_dirty = event_devices_dirty || devices_changed;
			remove_source (ref event_refresh_id);
			event_refresh_id = Timeout.add (EVENT_DEBOUNCE_MS, () => {
				event_refresh_id = 0U;
				refresh.begin ();
				if (event_devices_dirty && (outputs.size > 0 || inputs.size > 0))
					refresh_devices.begin ();
				event_devices_dirty = false;
				return false;
			});
		}

		void start_fallback_refresh ()
		{
			if (fallback_refresh_id > 0U)
				return;
			fallback_refresh_id = Timeout.add_seconds (FALLBACK_REFRESH_SECONDS, () => {
				refresh.begin ();
				return true;
			});
		}

		void set_state (AudioTarget target, bool available, double volume, bool muted)
		{
			bool changed;
			if (target == AudioTarget.OUTPUT) {
				changed = output_available != available || output_muted != muted
					|| Math.fabs (output_volume - volume) > 0.0005;
				output_available = available;
				output_volume = volume;
				output_muted = muted;
			} else {
				changed = input_available != available || input_muted != muted
					|| Math.fabs (input_volume - volume) > 0.0005;
				input_available = available;
				input_volume = volume;
				input_muted = muted;
			}
			if (changed)
				state_changed ();
		}

		static string target_name (AudioTarget target)
		{
			return target == AudioTarget.OUTPUT ? "@DEFAULT_AUDIO_SINK@" : "@DEFAULT_AUDIO_SOURCE@";
		}

		bool is_dirty (AudioTarget target) { return target == AudioTarget.OUTPUT ? output_dirty : input_dirty; }
		void set_dirty (AudioTarget target, bool value) { if (target == AudioTarget.OUTPUT) output_dirty = value; else input_dirty = value; }
		bool is_apply_running (AudioTarget target) { return target == AudioTarget.OUTPUT ? output_apply_running : input_apply_running; }
		void set_apply_running (AudioTarget target, bool value) { if (target == AudioTarget.OUTPUT) output_apply_running = value; else input_apply_running = value; }

		static void remove_source (ref uint source_id)
		{
			if (source_id > 0U) {
				Source.remove (source_id);
				source_id = 0U;
			}
		}
	}
}
