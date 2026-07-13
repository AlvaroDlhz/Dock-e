// Native reusable panel for the fixed system indicators.

namespace Plank
{
	public class StatusPanelWindow : Gtk.Window
	{
		const int PANEL_WIDTH = 245;
		const int PANEL_HEIGHT = 400;
		const int VOLUME_PANEL_SIZE = 400;
		const int BLUETOOTH_PANEL_SIZE = 400;
		const int WIFI_PANEL_SIZE = 400;
		const int BATTERY_PANEL_SIZE = 400;
		const int CLOCK_PANEL_SIZE = 400;
		const int PANEL_GAP = 10;

		unowned DockController controller;
		Gtk.Box content;
		Gtk.Box footer;
		StatusNoticeModel notice_model;
		Gtk.Revealer notice_revealer;
		Gtk.Label notice_label;
		ulong notice_changed_id = 0UL;
		StatusIndicatorItem? current_item;
		Gtk.CssProvider? css_provider;
		int active_panel_width = PANEL_WIDTH;
		int active_panel_height = PANEL_HEIGHT;
		bool device_popup_open = false;
		uint bluetooth_rebuild_id = 0U;
		bool bluetooth_discovery_owned = false;
		uint wifi_rebuild_id = 0U;
		uint clock_display_tick_id = 0U;
		uint countdown_tick_id = 0U;
		uint stopwatch_tick_id = 0U;
		int countdown_seconds = 0;
		int pomodoro_mode = 0;
		int stopwatch_seconds = 0;
		bool stopwatch_running = false;
		Gtk.Label? clock_time_label;
		Gtk.Label? clock_date_label;
		Gtk.Label? clock_zone_label;
		Gtk.Label? countdown_label;
		Gtk.Label? stopwatch_label;
		Gtk.Button? countdown_button;
		unowned AudioService audio_service;
		ulong audio_state_changed_id = 0UL;
		ulong audio_devices_changed_id = 0UL;
		Gtk.Scale? output_volume_scale;
		Gtk.Scale? input_volume_scale;
		Gtk.ToggleButton? output_mute_button;
		Gtk.ToggleButton? input_mute_button;
		Gtk.Label? output_volume_label;
		Gtk.Label? input_volume_label;
		Gtk.ComboBoxText? output_device_combo;
		Gtk.ComboBoxText? input_device_combo;
		bool updating_audio_controls = false;
		unowned BluetoothService bluetooth_service;
		ulong bluetooth_state_changed_id = 0UL;
		ulong bluetooth_devices_changed_id = 0UL;
		ulong bluetooth_operation_failed_id = 0UL;
		unowned NetworkService network_service;
		ulong network_state_changed_id = 0UL;
		ulong network_networks_changed_id = 0UL;
		ulong network_operation_failed_id = 0UL;
		unowned PowerService power_service;
		ulong power_state_changed_id = 0UL;
		ulong power_operation_failed_id = 0UL;
		unowned BrightnessService brightness_service;
		ulong brightness_state_changed_id = 0UL;
		ulong brightness_operation_failed_id = 0UL;
		Gtk.Scale? brightness_scale;
		Gtk.Label? brightness_value_label;
		bool updating_brightness_control = false;
		uint power_rebuild_id = 0U;

		public StatusPanelWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			notice_model = new StatusNoticeModel ();
			notice_changed_id = notice_model.changed.connect (sync_notice);
			audio_service = AudioService.get_default ();
			audio_state_changed_id = audio_service.state_changed.connect (sync_audio_controls);
			audio_devices_changed_id = audio_service.devices_changed.connect (sync_audio_devices);
			bluetooth_service = BluetoothService.get_default ();
			bluetooth_state_changed_id = bluetooth_service.state_changed.connect (bluetooth_service_changed);
			bluetooth_devices_changed_id = bluetooth_service.devices_changed.connect (bluetooth_service_changed);
			bluetooth_operation_failed_id = bluetooth_service.operation_failed.connect ((message) => {
				show_operation_error (StatusIndicatorKind.BLUETOOTH,
					_("Bluetooth could not complete that action. Please try again."), message);
			});
			network_service = NetworkService.get_default ();
			network_state_changed_id = network_service.state_changed.connect (network_service_changed);
			network_networks_changed_id = network_service.networks_changed.connect (network_service_changed);
			network_operation_failed_id = network_service.operation_failed.connect ((message) => {
				show_operation_error (StatusIndicatorKind.WIFI,
					_("Wi-Fi could not complete that action. Check the connection and try again."), message);
			});
			power_service = PowerService.get_default ();
			power_state_changed_id = power_service.state_changed.connect (power_service_changed);
			power_operation_failed_id = power_service.operation_failed.connect ((message) => {
				show_operation_error (StatusIndicatorKind.BATTERY,
					_("The power profile could not be changed."), message);
			});
			brightness_service = BrightnessService.get_default ();
			brightness_state_changed_id = brightness_service.state_changed.connect (brightness_service_changed);
			brightness_operation_failed_id = brightness_service.operation_failed.connect ((message) => {
				show_operation_error (StatusIndicatorKind.BATTERY,
					_("Screen brightness could not be changed."), message);
			});
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;
			set_keep_above (true);
			type_hint = Gdk.WindowTypeHint.DIALOG;
			set_default_size (PANEL_WIDTH, PANEL_HEIGHT);
			Gdk.Geometry geometry = {};
			geometry.min_width = PANEL_WIDTH;
			geometry.max_width = PANEL_WIDTH;
			geometry.min_height = PANEL_HEIGHT;
			geometry.max_height = PANEL_HEIGHT;
			set_geometry_hints (null, geometry,
				Gdk.WindowHints.MIN_SIZE | Gdk.WindowHints.MAX_SIZE);
			app_paintable = true;
			var visual = get_screen ().get_rgba_visual ();
			if (visual != null)
				set_visual (visual);
			get_style_context ().add_class ("plank-status-panel");

			var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			card.margin = 10;
			card.get_style_context ().add_class ("status-card");
			content = new Gtk.Box (Gtk.Orientation.VERTICAL, 3);
			notice_revealer = new Gtk.Revealer ();
			notice_revealer.transition_type = Gtk.RevealerTransitionType.NONE;
			var notice = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 7);
			notice.get_style_context ().add_class ("status-notice");
			notice.pack_start (new Gtk.Image.from_icon_name ("dialog-warning-symbolic",
				Gtk.IconSize.MENU), false, false, 0);
			notice_label = new Gtk.Label ("") { xalign = 0.0f, wrap = true, max_width_chars = 32 };
			notice.pack_start (notice_label, true, true, 0);
			var dismiss_notice = new Gtk.Button.from_icon_name ("window-close-symbolic",
				Gtk.IconSize.MENU);
			dismiss_notice.tooltip_text = _("Dismiss");
			dismiss_notice.get_style_context ().add_class ("status-notice-dismiss");
			dismiss_notice.clicked.connect (() => notice_model.dismiss ());
			notice.pack_end (dismiss_notice, false, false, 0);
			notice_revealer.add (notice);
			card.pack_start (notice_revealer, false, false, 0);
			var scroll = new Gtk.ScrolledWindow (null, null);
			scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			scroll.vscrollbar_policy = Gtk.PolicyType.NEVER;
			scroll.overlay_scrolling = true;
			scroll.propagate_natural_width = false;
			scroll.propagate_natural_height = false;
			scroll.get_style_context ().add_class ("status-scroll");
			scroll.add (content);
			card.pack_start (scroll, true, true, 0);
			footer = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			footer.get_style_context ().add_class ("status-footer");
			card.pack_end (footer, false, false, 0);
			add (card);
			sync_notice ();
			focus_out_event.connect (() => {
				if (!device_popup_open)
					dismiss ();
				return false;
			});
			show.connect (() => {
				controller.hide_manager.ExternalMenuVisible = true;
				controller.hide_manager.update_hovered ();
			});
			hide.connect (() => {
				controller.hide_manager.ExternalMenuVisible = false;
				controller.hide_manager.update_hovered ();
			});
		}

		~StatusPanelWindow ()
		{
			if (notice_changed_id > 0UL)
				SignalHandler.disconnect (notice_model, notice_changed_id);
			if (audio_state_changed_id > 0UL)
				SignalHandler.disconnect (audio_service, audio_state_changed_id);
			if (audio_devices_changed_id > 0UL)
				SignalHandler.disconnect (audio_service, audio_devices_changed_id);
			if (bluetooth_state_changed_id > 0UL)
				SignalHandler.disconnect (bluetooth_service, bluetooth_state_changed_id);
			if (bluetooth_devices_changed_id > 0UL)
				SignalHandler.disconnect (bluetooth_service, bluetooth_devices_changed_id);
			if (bluetooth_operation_failed_id > 0UL)
				SignalHandler.disconnect (bluetooth_service, bluetooth_operation_failed_id);
			if (network_state_changed_id > 0UL)
				SignalHandler.disconnect (network_service, network_state_changed_id);
			if (network_networks_changed_id > 0UL)
				SignalHandler.disconnect (network_service, network_networks_changed_id);
			if (network_operation_failed_id > 0UL)
				SignalHandler.disconnect (network_service, network_operation_failed_id);
			if (power_state_changed_id > 0UL)
				SignalHandler.disconnect (power_service, power_state_changed_id);
			if (power_operation_failed_id > 0UL)
				SignalHandler.disconnect (power_service, power_operation_failed_id);
			if (brightness_state_changed_id > 0UL)
				SignalHandler.disconnect (brightness_service, brightness_state_changed_id);
			if (brightness_operation_failed_id > 0UL)
				SignalHandler.disconnect (brightness_service, brightness_operation_failed_id);
			if (bluetooth_rebuild_id > 0U)
				Source.remove (bluetooth_rebuild_id);
			stop_bluetooth_discovery ();
			if (wifi_rebuild_id > 0U)
				Source.remove (wifi_rebuild_id);
			if (power_rebuild_id > 0U)
				Source.remove (power_rebuild_id);
			stop_clock_display ();
			if (countdown_tick_id > 0U) Source.remove (countdown_tick_id);
			if (stopwatch_tick_id > 0U) Source.remove (stopwatch_tick_id);
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
		}

		public void toggle (StatusIndicatorItem item)
		{
			if (visible && current_item == item) {
				dismiss ();
				return;
			}
			if (current_item != null && current_item.Kind == StatusIndicatorKind.BLUETOOTH
				&& item.Kind != StatusIndicatorKind.BLUETOOTH)
				stop_bluetooth_discovery ();
			if (current_item != null && current_item.Kind == StatusIndicatorKind.CLOCK
				&& item.Kind != StatusIndicatorKind.CLOCK)
				stop_clock_display ();
			if (current_item != null && current_item.Kind != item.Kind)
				notice_model.dismiss ();
			current_item = item;
			apply_geometry (item.Kind);
			if (item.Kind == StatusIndicatorKind.BLUETOOTH)
				start_bluetooth_discovery ();
			if (item.Kind == StatusIndicatorKind.WIFI)
				network_service.request_scan.begin ();
			if (item.Kind == StatusIndicatorKind.BATTERY)
				brightness_service.refresh.begin ();
			rebuild (item.Kind);
			if (item.Kind == StatusIndicatorKind.CLOCK)
				start_clock_display ();
			apply_theme ();
			opacity = 0.0;
			show_all ();
			present ();
			Idle.add (() => {
				resize (active_panel_width, active_panel_height);
				position_over_item ();
				opacity = 1.0;
				Idle.add (() => { position_over_item (); return false; });
				return false;
			});
		}

		void show_operation_error (StatusIndicatorKind kind, string user_message,
			string technical_message)
		{
			warning ("%s operation failed: %s", label_for_kind (kind), technical_message);
			if (current_item != null && current_item.Kind == kind)
				notice_model.show_error (user_message);
		}

		void sync_notice ()
		{
			notice_label.label = notice_model.message;
			notice_revealer.reveal_child = notice_model.visible;
		}

		void apply_geometry (StatusIndicatorKind kind)
		{
			if (kind == StatusIndicatorKind.VOLUME) {
				var workarea = active_workarea ();
				var bar = controller.position_manager.get_screen_background_region ();
				var available_above = bar.y - PANEL_GAP - workarea.y;
				var square_size = int.min (VOLUME_PANEL_SIZE,
					int.min (workarea.width - 20, available_above));
				active_panel_width = active_panel_height = int.max (160, square_size);
			} else if (kind == StatusIndicatorKind.BLUETOOTH) {
				active_panel_width = active_panel_height = BLUETOOTH_PANEL_SIZE;
			} else if (kind == StatusIndicatorKind.WIFI) {
				active_panel_width = active_panel_height = WIFI_PANEL_SIZE;
			} else if (kind == StatusIndicatorKind.BATTERY) {
				active_panel_width = active_panel_height = BATTERY_PANEL_SIZE;
			} else if (kind == StatusIndicatorKind.CLOCK) {
				active_panel_width = active_panel_height = CLOCK_PANEL_SIZE;
			} else {
				active_panel_width = PANEL_WIDTH;
				active_panel_height = PANEL_HEIGHT;
			}
			Gdk.Geometry geometry = {};
			geometry.min_width = active_panel_width;
			geometry.max_width = active_panel_width;
			geometry.min_height = active_panel_height;
			geometry.max_height = active_panel_height;
			set_geometry_hints (null, geometry,
				Gdk.WindowHints.MIN_SIZE | Gdk.WindowHints.MAX_SIZE);
			set_size_request (active_panel_width, active_panel_height);
			set_default_size (active_panel_width, active_panel_height);
			resize (active_panel_width, active_panel_height);
		}

		public void dismiss ()
		{
			if (current_item != null && current_item.Kind == StatusIndicatorKind.BLUETOOTH)
				stop_bluetooth_discovery ();
			if (current_item != null && current_item.Kind == StatusIndicatorKind.CLOCK)
				stop_clock_display ();
			if (visible)
				hide ();
		}

		void rebuild (StatusIndicatorKind kind)
		{
			output_volume_scale = null;
			input_volume_scale = null;
			output_mute_button = null;
			input_mute_button = null;
			output_volume_label = null;
			input_volume_label = null;
			output_device_combo = null;
			input_device_combo = null;
			clock_time_label = null;
			clock_date_label = null;
			clock_zone_label = null;
			countdown_label = null;
			stopwatch_label = null;
			countdown_button = null;
			brightness_scale = null;
			brightness_value_label = null;
			foreach (unowned Gtk.Widget child in content.get_children ())
				content.remove (child);
			foreach (unowned Gtk.Widget child in footer.get_children ())
				footer.remove (child);
			content.pack_start (title_row (label_for_kind (kind), icon_for_kind (kind)), false, false, 0);
			content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);
			switch (kind) {
			case StatusIndicatorKind.VOLUME: build_volume (); break;
			case StatusIndicatorKind.BLUETOOTH: build_bluetooth (); break;
			case StatusIndicatorKind.WIFI: build_wifi (); break;
			case StatusIndicatorKind.BATTERY: build_battery (); break;
			case StatusIndicatorKind.CLOCK: build_clock (); break;
			default: break;
			}
		}

		Gtk.Widget title_row (string title, string icon)
		{
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.get_style_context ().add_class ("status-title");
			box.pack_start (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.BUTTON), false, false, 0);
			var label = new Gtk.Label (title) { xalign = 0.0f };
			label.get_style_context ().add_class ("status-title-label");
			box.pack_start (label, true, true, 0);
			return box;
		}

		void build_volume ()
		{
			content.pack_start (section_label (_("Output")), false, false, 0);
			content.pack_start (device_selector (AudioTarget.OUTPUT), false, false, 0);
			content.pack_start (modern_volume_bar (AudioTarget.OUTPUT, 150,
				"audio-volume-high-symbolic"), false, false, 0);

			content.pack_start (section_label (_("Microphone")), false, false, 0);
			content.pack_start (device_selector (AudioTarget.INPUT), false, false, 0);
			content.pack_start (modern_volume_bar (AudioTarget.INPUT, 100,
				"audio-input-microphone-symbolic"), false, false, 0);

			var settings = new Gtk.Button.with_label (_("Advanced sound settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("pavucontrol"));
			footer.pack_start (settings, false, false, 0);
			audio_service.refresh.begin ();
			audio_service.refresh_devices.begin ();
		}

		Gtk.Widget modern_volume_bar (AudioTarget target, double maximum, string icon_name)
		{
			var percent = audio_service.get_volume (target) * 100.0;
			var overlay = new Gtk.Overlay ();
			overlay.get_style_context ().add_class ("modern-volume-bar");
			var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0, maximum, 1);
			scale.draw_value = false;
			scale.has_origin = true;
			scale.height_request = 36;
			scale.set_value (percent);
			scale.get_style_context ().add_class ("modern-volume-scale");
			overlay.add (scale);

			var icon = icon_toggle_button (icon_name, audio_service.is_muted (target));
			icon.halign = Gtk.Align.START;
			icon.valign = Gtk.Align.CENTER;
			icon.margin_start = 5;
			icon.toggled.connect (() => {
				if (!updating_audio_controls)
					audio_service.set_muted.begin (target, icon.active);
			});
			overlay.add_overlay (icon);

			var value = new Gtk.Label ("%.0f%%".printf (percent));
			value.halign = Gtk.Align.END;
			value.valign = Gtk.Align.CENTER;
			value.margin_end = 10;
			value.get_style_context ().add_class ("modern-volume-value");
			overlay.add_overlay (value);
			overlay.set_overlay_pass_through (value, true);
			scale.value_changed.connect (() => {
				value.label = "%.0f%%".printf (scale.get_value ());
				if (!updating_audio_controls)
					audio_service.set_volume (target, scale.get_value () / 100.0);
			});
			if (target == AudioTarget.OUTPUT) {
				output_volume_scale = scale;
				output_mute_button = icon;
				output_volume_label = value;
			} else {
				input_volume_scale = scale;
				input_mute_button = icon;
				input_volume_label = value;
			}
			return overlay;
		}

		Gtk.ToggleButton icon_toggle_button (string icon, bool active)
		{
			var button = new Gtk.ToggleButton ();
			button.active = active;
			button.get_style_context ().add_class ("status-icon-toggle");
			button.add (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.MENU));
			return button;
		}

		Gtk.Widget section_label (string text)
		{
			var label = new Gtk.Label (text) { xalign = 0.0f };
			label.get_style_context ().add_class ("status-section-label");
			return label;
		}

		Gtk.Widget device_selector (AudioTarget target)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			row.get_style_context ().add_class ("status-row");
			var combo = new Gtk.ComboBoxText ();
			combo.get_style_context ().add_class ("modern-device-selector");
			foreach (unowned Gtk.CellRenderer renderer in combo.get_cells ()) {
				var text_renderer = renderer as Gtk.CellRendererText;
				if (text_renderer != null) {
					text_renderer.ellipsize = Pango.EllipsizeMode.END;
					text_renderer.width_chars = 14;
				}
			}
			populate_audio_combo (combo, target);
			combo.notify["popup-shown"].connect (() => {
				device_popup_open = combo.popup_shown;
				if (!device_popup_open && visible) {
					sync_audio_devices ();
					Idle.add (() => { present (); return false; });
				}
			});
			combo.changed.connect (() => {
				if (!updating_audio_controls && combo.active_id != null)
					audio_service.set_default_device.begin (target, combo.active_id);
			});
			if (target == AudioTarget.OUTPUT)
				output_device_combo = combo;
			else
				input_device_combo = combo;
			row.pack_start (combo, true, true, 0);
			return row;
		}

		void populate_audio_combo (Gtk.ComboBoxText combo, AudioTarget target)
		{
			combo.remove_all ();
			foreach (AudioDevice device in audio_service.get_devices (target))
				combo.append (device.id, friendly_device_name (device.name));
			combo.active_id = audio_service.get_default_device (target);
		}

		string friendly_device_name (string name)
		{
			var result = name.replace ("alsa_output.", "").replace ("alsa_input.", "");
			result = result.replace ("bluez_output.", "Bluetooth · ").replace ("bluez_input.", "Bluetooth · ");
			result = result.replace ("_", " ").replace (".", " · ");
			return result;
		}

		void sync_audio_controls ()
		{
			if (current_item == null || current_item.Kind != StatusIndicatorKind.VOLUME)
				return;
			updating_audio_controls = true;
			update_audio_control (AudioTarget.OUTPUT, output_volume_scale,
				output_mute_button, output_volume_label);
			update_audio_control (AudioTarget.INPUT, input_volume_scale,
				input_mute_button, input_volume_label);
			updating_audio_controls = false;
		}

		void update_audio_control (AudioTarget target, Gtk.Scale? scale,
			Gtk.ToggleButton? mute_button, Gtk.Label? value_label)
		{
			var percent = audio_service.get_volume (target) * 100.0;
			if (scale != null && Math.fabs (scale.get_value () - percent) > 0.5)
				scale.set_value (percent);
			if (mute_button != null)
				mute_button.active = audio_service.is_muted (target);
			if (value_label != null)
				value_label.label = "%.0f%%".printf (percent);
		}

		void sync_audio_devices ()
		{
			if (device_popup_open || current_item == null
				|| current_item.Kind != StatusIndicatorKind.VOLUME)
				return;
			updating_audio_controls = true;
			if (output_device_combo != null)
				populate_audio_combo (output_device_combo, AudioTarget.OUTPUT);
			if (input_device_combo != null)
				populate_audio_combo (input_device_combo, AudioTarget.INPUT);
			updating_audio_controls = false;
		}

		void build_bluetooth ()
		{
			if (!bluetooth_service.available) {
				content.pack_start (info_row (_("Bluetooth is not available"),
					_("No Bluetooth adapter was found")), false, false, 0);
				add_bluetooth_settings_button ();
				return;
			}
			var powered = bluetooth_service.powered;
			var adapter_state = powered ? _("On") : _("Off");
			content.pack_start (switch_row (_("Bluetooth · %s").printf (adapter_state), powered, (state) => {
				if (!state)
					stop_bluetooth_discovery ();
				bluetooth_service.change_powered.begin (state);
			}, !bluetooth_service.busy), false, false, 0);
			if (!powered) {
				content.pack_start (info_row (_("Bluetooth is turned off"),
					_("Turn it on to see nearby devices")), false, false, 0);
				add_bluetooth_settings_button ();
				return;
			}

			var connected_count = 0;
			var known_count = 0;
			var nearby_count = 0;
			var connected_rows = new Gee.ArrayList<Gtk.Widget> ();
			var known_rows = new Gee.ArrayList<Gtk.Widget> ();
			var nearby_rows = new Gee.ArrayList<Gtk.Widget> ();
			foreach (BluetoothDevice device in bluetooth_service.get_devices ()) {
				var row = bluetooth_device_row (device);
				if (device.connected) { connected_rows.add (row); connected_count++; }
				else if (device.paired) { known_rows.add (row); known_count++; }
				else if (nearby_count < 3) { nearby_rows.add (row); nearby_count++; }
			}
			if (connected_count > 0) {
				content.pack_start (section_label (_("Connected")), false, false, 0);
				foreach (var row in connected_rows) content.pack_start (row, false, false, 0);
			}
			if (known_count > 0) {
				content.pack_start (section_label (_("Known devices")), false, false, 0);
				foreach (var row in known_rows) content.pack_start (row, false, false, 0);
			}
			if (nearby_count > 0) {
				content.pack_start (section_label (_("Nearby")), false, false, 0);
				foreach (var row in nearby_rows) content.pack_start (row, false, false, 0);
			}

			if (connected_count + known_count + nearby_count == 0)
				content.pack_start (info_row (_("No devices found"),
					bluetooth_service.discovering ? _("Searching for nearby devices")
						: _("Open this panel to search for nearby devices")), false, false, 0);

			add_bluetooth_settings_button ();
		}

		void start_bluetooth_discovery ()
		{
			if (bluetooth_service.powered && !bluetooth_discovery_owned) {
				bluetooth_discovery_owned = true;
				bluetooth_service.change_discovery (true);
			}
		}

		void stop_bluetooth_discovery ()
		{
			if (bluetooth_discovery_owned)
				bluetooth_service.change_discovery (false);
			bluetooth_discovery_owned = false;
		}

		Gtk.Widget bluetooth_device_row (BluetoothDevice device)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			row.get_style_context ().add_class ("bluetooth-device-row");
			row.pack_start (new Gtk.Image.from_icon_name ("bluetooth-symbolic", Gtk.IconSize.BUTTON), false, false, 0);
			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var title = new Gtk.Label (device.name) { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			var state = device.connected ? _("Connected") : (device.paired ? _("Known device") : _("Nearby"));
			if (device.battery_percentage >= 0)
				state += " · %d%%".printf (device.battery_percentage);
			var subtitle = new Gtk.Label (state) { xalign = 0.0f };
			subtitle.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (title, false, false, 0);
			labels.pack_start (subtitle, false, false, 0);
			row.pack_start (labels, true, true, 0);
			var action = new Gtk.Button.with_label (device.connected ? _("Disconnect") : _("Connect"));
			action.get_style_context ().add_class ("bluetooth-device-action");
			action.sensitive = !bluetooth_service.busy;
			action.clicked.connect (() => {
				action.sensitive = false;
				bluetooth_service.set_connected.begin (device, !device.connected);
			});
			row.pack_end (action, false, false, 0);
			if (device.paired && !device.connected) {
				var forget = new Gtk.Button.from_icon_name ("edit-delete-symbolic", Gtk.IconSize.MENU);
				forget.tooltip_text = _("Forget device");
				forget.get_style_context ().add_class ("bluetooth-device-action");
				forget.sensitive = !bluetooth_service.busy;
				forget.clicked.connect (() => {
					forget.sensitive = false;
					bluetooth_service.remove_device.begin (device);
				});
				row.pack_end (forget, false, false, 0);
			}
			return row;
		}

		void bluetooth_service_changed ()
		{
			if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.BLUETOOTH)
				return;
			if (bluetooth_service.powered && !bluetooth_discovery_owned)
				start_bluetooth_discovery ();
			if (bluetooth_rebuild_id > 0U)
				Source.remove (bluetooth_rebuild_id);
			bluetooth_rebuild_id = Timeout.add (75, () => {
				bluetooth_rebuild_id = 0U;
				if (visible && current_item != null && current_item.Kind == StatusIndicatorKind.BLUETOOTH) {
					rebuild (StatusIndicatorKind.BLUETOOTH);
					show_all ();
				}
				return false;
			});
		}

		void add_bluetooth_settings_button ()
		{
			var settings = new Gtk.Button.with_label (_("Advanced Bluetooth settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("blueman-manager"));
			footer.pack_start (settings, false, false, 0);
		}

		void build_wifi ()
		{
			var enabled = network_service.available && network_service.enabled;
			content.pack_start (switch_row (_("Wi-Fi · %s").printf (enabled ? _("On") : _("Off")), enabled, (state) => {
				network_service.change_enabled.begin (state);
			}, network_service.available && !network_service.busy), false, false, 0);
			if (!network_service.available) {
				content.pack_start (info_row (_("Wi-Fi is unavailable"),
					_("No wireless adapter was detected")), false, false, 0);
				add_wifi_settings_button ();
				return;
			}
			if (!enabled) {
				content.pack_start (info_row (_("Wi-Fi is turned off"),
					_("Turn it on to see nearby networks")), false, false, 0);
				add_wifi_settings_button ();
				return;
			}

			var connected_rows = new Gee.ArrayList<Gtk.Widget> ();
			var known_rows = new Gee.ArrayList<Gtk.Widget> ();
			var nearby_rows = new Gee.ArrayList<Gtk.Widget> ();
			foreach (WifiNetwork network in network_service.get_networks ()) {
				var row = wifi_network_row (network);
				if (network.connected) connected_rows.add (row);
				else if (network.saved) known_rows.add (row);
				else nearby_rows.add (row);
			}

			if (connected_rows.size > 0) {
				content.pack_start (section_label (_("Connected")), false, false, 0);
				foreach (var row in connected_rows) content.pack_start (row, false, false, 0);
			}
			var available = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			available.get_style_context ().add_class ("wifi-networks-list");
			if (known_rows.size > 0) {
				available.pack_start (section_label (_("Known networks")), false, false, 0);
				foreach (var row in known_rows) available.pack_start (row, false, false, 0);
			}
			if (nearby_rows.size > 0) {
				available.pack_start (section_label (_("Nearby networks")), false, false, 0);
				foreach (var row in nearby_rows) available.pack_start (row, false, false, 0);
			}
			if (known_rows.size + nearby_rows.size == 0)
				available.pack_start (info_row (_("No networks found"), _("Scanning for nearby networks…")), false, false, 0);
			var networks_scroll = new Gtk.ScrolledWindow (null, null);
			networks_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			networks_scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
			networks_scroll.overlay_scrolling = true;
			networks_scroll.height_request = connected_rows.size > 0 ? 205 : 270;
			networks_scroll.get_style_context ().add_class ("wifi-networks-scroll");
			networks_scroll.add (available);
			content.pack_start (networks_scroll, true, true, 0);
			add_wifi_settings_button ();
		}

		Gtk.Widget wifi_network_row (WifiNetwork network)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			row.get_style_context ().add_class ("wifi-network-row");
			row.pack_start (new Gtk.Image.from_icon_name (wifi_signal_icon (network.strength), Gtk.IconSize.BUTTON), false, false, 0);
			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var title = new Gtk.Label (network.ssid) { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			var detail = network.connected ? _("Connected") : _("Signal %d%%").printf (network.strength);
			if (network.connected && network_service.ip_address != "")
				detail += " · " + network_service.ip_address;
			if (network.secure) detail += " · " + _("Secured");
			var subtitle = new Gtk.Label (detail) { xalign = 0.0f };
			subtitle.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (title, false, false, 0);
			labels.pack_start (subtitle, false, false, 0);
			row.pack_start (labels, true, true, 0);
			var action = new Gtk.Button.with_label (network.connected ? _("Disconnect") : _("Connect"));
			action.get_style_context ().add_class ("wifi-network-action");
			action.sensitive = !network_service.busy;
			action.clicked.connect (() => {
				action.sensitive = false;
				if (network.connected)
					network_service.disconnect_network.begin ();
				else if (network.saved)
					network_service.connect_network.begin (network);
				else if (network.secure)
					prompt_wifi_password (network);
				else
					network_service.connect_network.begin (network);
			});
			row.pack_end (action, false, false, 0);
			if (network.saved && !network.connected) {
				var forget = new Gtk.Button.from_icon_name ("edit-delete-symbolic", Gtk.IconSize.MENU);
				forget.tooltip_text = _("Forget network");
				forget.get_style_context ().add_class ("wifi-network-action");
				forget.sensitive = !network_service.busy;
				forget.clicked.connect (() => {
					forget.sensitive = false;
					network_service.forget_network.begin (network);
				});
				row.pack_end (forget, false, false, 0);
			}
			return row;
		}

		string wifi_signal_icon (int value)
		{
			if (value >= 75) return "network-wireless-signal-excellent-symbolic";
			if (value >= 50) return "network-wireless-signal-good-symbolic";
			if (value >= 25) return "network-wireless-signal-ok-symbolic";
			return "network-wireless-signal-weak-symbolic";
		}

		void prompt_wifi_password (WifiNetwork network)
		{
			device_popup_open = true;
			var dialog = new Gtk.Dialog.with_buttons (_("Connect to %s").printf (network.ssid), this,
				Gtk.DialogFlags.MODAL, _("Cancel"), Gtk.ResponseType.CANCEL,
				_("Connect"), Gtk.ResponseType.OK);
			var entry = new Gtk.Entry ();
			entry.visibility = false;
			entry.activates_default = true;
			entry.placeholder_text = _("Wi-Fi password");
			entry.margin = 12;
			dialog.get_content_area ().pack_start (entry, false, false, 0);
			dialog.set_default_response (Gtk.ResponseType.OK);
			dialog.response.connect ((response) => {
				if (response == Gtk.ResponseType.OK && entry.text != "")
					network_service.connect_network.begin (network, entry.text);
				dialog.destroy ();
				device_popup_open = false;
			});
			dialog.show_all ();
		}

		void network_service_changed ()
		{
			if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.WIFI)
				return;
			if (wifi_rebuild_id > 0U)
				Source.remove (wifi_rebuild_id);
			wifi_rebuild_id = Timeout.add (100, () => {
				wifi_rebuild_id = 0U;
				if (visible && current_item != null && current_item.Kind == StatusIndicatorKind.WIFI) {
					rebuild (StatusIndicatorKind.WIFI);
					show_all ();
				}
				return false;
			});
		}

		void power_service_changed ()
		{
			if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.BATTERY)
				return;
			if (power_rebuild_id > 0U)
				Source.remove (power_rebuild_id);
			power_rebuild_id = Timeout.add (100, () => {
				power_rebuild_id = 0U;
				if (visible && current_item != null && current_item.Kind == StatusIndicatorKind.BATTERY) {
					rebuild (StatusIndicatorKind.BATTERY);
					show_all ();
				}
				return false;
			});
		}

		void brightness_service_changed ()
		{
			if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.BATTERY)
				return;
			if (brightness_scale == null || !brightness_service.available) {
				power_service_changed ();
				return;
			}
			updating_brightness_control = true;
			brightness_scale.set_value (brightness_service.percentage);
			if (brightness_value_label != null)
				brightness_value_label.label = "%.0f%%".printf (brightness_service.percentage);
			updating_brightness_control = false;
		}

		void add_wifi_settings_button ()
		{
			var settings = new Gtk.Button.with_label (_("Advanced network settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("nm-connection-editor"));
			footer.pack_start (settings, false, false, 0);
		}

		void build_battery ()
		{
			if (!power_service.battery_available) {
				content.pack_start (info_row (_("No battery detected"),
					_("This device may be running on external power")), false, false, 0);
				build_power_profiles ();
				build_brightness_control ();
				add_power_settings_button ();
				return;
			}

			var summary = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
			summary.get_style_context ().add_class ("battery-summary");
			var percentage = new Gtk.Label ("%.0f%%".printf (power_service.percentage));
			percentage.get_style_context ().add_class ("battery-percentage");
			summary.pack_start (percentage, false, false, 0);
			var status_label = new Gtk.Label (battery_status_text ());
			status_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			summary.pack_start (status_label, false, false, 0);
			content.pack_start (summary, false, false, 0);

			content.pack_start (section_label (_("Energy")), false, false, 0);
			content.pack_start (metric_row (_("Current consumption"),
				power_service.energy_rate > 0.01
					? "%.1f W".printf (power_service.energy_rate) : _("Not available")), false, false, 0);
			content.pack_start (metric_row (_("Battery health"),
				power_service.capacity > 0
					? "%.0f%%".printf (power_service.capacity) : _("Not available")), false, false, 0);
			content.pack_start (metric_row (_("Charge cycles"),
				power_service.charge_cycles >= 0
					? "%d".printf (power_service.charge_cycles) : _("Not available")), false, false, 0);

			build_power_profiles ();
			build_brightness_control ();
			add_power_settings_button ();
		}

		Gtk.Widget metric_row (string label, string value)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			row.get_style_context ().add_class ("battery-metric-row");
			row.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			var result = new Gtk.Label (value) { xalign = 1.0f };
			result.get_style_context ().add_class ("battery-metric-value");
			row.pack_end (result, false, false, 0);
			return row;
		}

		void build_power_profiles ()
		{
			if (!power_service.profiles_available)
				return;
			content.pack_start (section_label (_("Power profile")), false, false, 0);
			var profiles = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
			profiles.get_style_context ().add_class ("power-profiles");
			Gtk.RadioButton? first_profile = null;
			foreach (string id in power_service.get_profiles ()) {
				var profile_id = id;
				var button = first_profile == null
					? new Gtk.RadioButton.with_label (null, profile_label (profile_id))
					: new Gtk.RadioButton.with_label_from_widget (first_profile, profile_label (profile_id));
				if (first_profile == null) first_profile = button;
				button.active = power_service.active_profile == profile_id;
				button.sensitive = !power_service.busy;
				button.get_style_context ().add_class ("power-profile-button");
				button.toggled.connect (() => {
					if (button.active && profile_id != power_service.active_profile)
						power_service.change_profile.begin (profile_id);
				});
				profiles.pack_start (button, true, true, 0);
			}
			content.pack_start (profiles, false, false, 0);
		}

		void build_brightness_control ()
		{
			if (!brightness_service.available) return;
			content.pack_start (section_label (_("Screen brightness")), false, false, 0);
			var overlay = new Gtk.Overlay ();
			overlay.get_style_context ().add_class ("modern-volume-bar");
			var scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 5, 100, 1);
			brightness_scale = scale;
			scale.draw_value = false;
			scale.has_origin = true;
			scale.height_request = 36;
			scale.set_value (brightness_service.percentage);
			scale.get_style_context ().add_class ("modern-volume-scale");
			overlay.add (scale);
			scale.button_release_event.connect (() => {
				if (!updating_brightness_control)
					brightness_service.request_percentage (scale.get_value ());
				return false;
			});
			var icon = new Gtk.Image.from_icon_name ("display-brightness-symbolic", Gtk.IconSize.MENU);
			icon.halign = Gtk.Align.START;
			icon.valign = Gtk.Align.CENTER;
			icon.margin_start = 10;
			overlay.add_overlay (icon);
			overlay.set_overlay_pass_through (icon, true);
			var value = new Gtk.Label ("%.0f%%".printf (scale.get_value ())) { width_request = 38, xalign = 1.0f };
			brightness_value_label = value;
			value.halign = Gtk.Align.END;
			value.valign = Gtk.Align.CENTER;
			value.margin_end = 10;
			value.get_style_context ().add_class ("modern-volume-value");
			scale.value_changed.connect (() => value.label = "%.0f%%".printf (scale.get_value ()));
			overlay.add_overlay (value);
			overlay.set_overlay_pass_through (value, true);
			content.pack_start (overlay, false, false, 0);
		}

		string battery_status_text ()
		{
			var seconds = power_service.is_charging ()
				? power_service.time_to_full : power_service.time_to_empty;
			if (seconds > 0) {
				var minutes = (int) Math.round (seconds / 60.0);
				var time = _("%d h %02d min").printf (minutes / 60, minutes % 60);
				return power_service.is_charging () ? _("%s until full").printf (time)
					: _("%s remaining").printf (time);
			}
			switch (power_service.battery_state) {
			case BatteryState.CHARGING:
			case BatteryState.PENDING_CHARGE: return _("Charging");
			case BatteryState.DISCHARGING:
			case BatteryState.PENDING_DISCHARGE: return _("On battery");
			case BatteryState.FULLY_CHARGED: return _("Fully charged");
			case BatteryState.EMPTY: return _("Empty");
			default: return _("Battery status unavailable");
			}
		}

		string profile_label (string id)
		{
			switch (id) {
			case "power-saver": return _("Saver");
			case "performance": return _("Performance");
			default: return _("Balanced");
			}
		}

		void add_power_settings_button ()
		{
			var settings = new Gtk.Button.with_label (_("Advanced power settings"));
			settings.get_style_context ().add_class ("status-action-button");
			settings.clicked.connect (() => launch ("xfce4-power-manager-settings"));
			footer.pack_start (settings, false, false, 0);
		}

		void build_clock ()
		{
			var now = new DateTime.now_local ();
			var stack = new Gtk.Stack ();
			stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
			stack.transition_duration = 120;
			stack.get_style_context ().add_class ("clock-stack");
			var switcher = new Gtk.StackSwitcher ();
			switcher.stack = stack;
			switcher.homogeneous = true;
			switcher.get_style_context ().add_class ("clock-tabs");
			content.pack_start (switcher, false, false, 0);
			content.pack_start (stack, true, true, 0);

			var time_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
			time_page.get_style_context ().add_class ("clock-page");
			var summary = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			summary.get_style_context ().add_class ("clock-summary");
			clock_time_label = new Gtk.Label (now.format ("%H:%M:%S"));
			clock_time_label.get_style_context ().add_class ("clock-time");
			clock_date_label = new Gtk.Label (now.format ("%A, %e %B %Y"));
			clock_date_label.get_style_context ().add_class ("clock-date");
			clock_zone_label = new Gtk.Label (timezone_name (now));
			clock_zone_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			summary.pack_start (clock_time_label, false, false, 0);
			summary.pack_start (clock_date_label, false, false, 0);
			summary.pack_start (clock_zone_label, false, false, 0);
			time_page.pack_start (summary, true, true, 0);
			var copy = new Gtk.Button.with_label (_("Copy date and time"));
			copy.get_style_context ().add_class ("status-action-button");
			copy.clicked.connect (() => {
				Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD).set_text (
					new DateTime.now_local ().format ("%Y-%m-%d %H:%M:%S"), -1);
			});
			time_page.pack_end (copy, false, false, 0);
			stack.add_titled (time_page, "time", _("Time"));

			var calendar_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
			calendar_page.get_style_context ().add_class ("clock-page");
			var calendar = new Gtk.Calendar ();
			calendar.show_heading = true;
			calendar.show_day_names = true;
			calendar.get_style_context ().add_class ("clock-calendar");
			calendar_page.pack_start (calendar, true, true, 0);
			stack.add_titled (calendar_page, "calendar", _("Calendar"));

			var pomodoro_page = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
			pomodoro_page.get_style_context ().add_class ("clock-page");
			var pomodoro_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
			var pomodoro_title = new Gtk.Label (_("Pomodoro focus"));
			pomodoro_title.get_style_context ().add_class ("clock-tool-title");
			pomodoro_box.pack_start (pomodoro_title, false, false, 0);
			var mode_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 5);
			mode_row.halign = Gtk.Align.CENTER;
			var focus_mode = new Gtk.RadioButton.with_label (null, _("Focus · 25 min"));
			var break_mode = new Gtk.RadioButton.with_label_from_widget (focus_mode, _("Break · 5 min"));
			var long_break_mode = new Gtk.RadioButton.with_label_from_widget (focus_mode, _("Long · 15 min"));
			focus_mode.active = pomodoro_mode == 0;
			break_mode.active = pomodoro_mode == 1;
			long_break_mode.active = pomodoro_mode == 2;
			focus_mode.get_style_context ().add_class ("clock-tool-button");
			break_mode.get_style_context ().add_class ("clock-tool-button");
			long_break_mode.get_style_context ().add_class ("clock-tool-button");
			mode_row.pack_start (focus_mode, false, false, 0);
			mode_row.pack_start (break_mode, false, false, 0);
			mode_row.pack_start (long_break_mode, false, false, 0);
			pomodoro_box.pack_start (mode_row, false, false, 0);
			countdown_label = new Gtk.Label (format_duration (countdown_seconds > 0 ? countdown_seconds : 25 * 60));
			countdown_label.get_style_context ().add_class ("clock-counter");
			pomodoro_box.pack_start (countdown_label, true, true, 0);
			var pomodoro_actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
			pomodoro_actions.halign = Gtk.Align.CENTER;
			var start_button = new Gtk.Button.with_label (countdown_tick_id > 0U ? _("Pause") : _("Start"));
			countdown_button = start_button;
			start_button.get_style_context ().add_class ("clock-tool-button");
			start_button.clicked.connect (() => {
				if (countdown_tick_id > 0U) {
					pause_countdown ();
					start_button.label = _("Start");
				} else {
					if (countdown_seconds == 0)
						countdown_seconds = pomodoro_duration ();
					resume_countdown ();
					start_button.label = _("Pause");
				}
			});
			var reset = new Gtk.Button.from_icon_name ("view-refresh-symbolic", Gtk.IconSize.MENU);
			reset.tooltip_text = _("Reset Pomodoro");
			reset.get_style_context ().add_class ("clock-tool-button");
			reset.clicked.connect (() => {
				stop_countdown ();
				countdown_seconds = pomodoro_duration ();
				if (countdown_label != null) countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			focus_mode.toggled.connect (() => {
				if (!focus_mode.active) return;
				pomodoro_mode = 0;
				stop_countdown (); countdown_seconds = 25 * 60;
				countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			break_mode.toggled.connect (() => {
				if (!break_mode.active) return;
				pomodoro_mode = 1;
				stop_countdown (); countdown_seconds = 5 * 60;
				countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			long_break_mode.toggled.connect (() => {
				if (!long_break_mode.active) return;
				pomodoro_mode = 2;
				stop_countdown (); countdown_seconds = 15 * 60;
				countdown_label.label = format_duration (countdown_seconds);
				start_button.label = _("Start");
			});
			pomodoro_actions.pack_start (start_button, false, false, 0);
			pomodoro_actions.pack_start (reset, false, false, 0);
			pomodoro_box.pack_end (pomodoro_actions, false, false, 0);
			pomodoro_page.pack_start (pomodoro_box, true, true, 0);
			stack.add_titled (pomodoro_page, "pomodoro", _("Pomodoro"));
		}

		void start_clock_display ()
		{
			stop_clock_display ();
			update_clock_labels ();
			clock_display_tick_id = Timeout.add_seconds (1, () => {
				if (!visible || current_item == null || current_item.Kind != StatusIndicatorKind.CLOCK) {
					clock_display_tick_id = 0U;
					return false;
				}
				update_clock_labels ();
				return true;
			});
		}

		void stop_clock_display ()
		{
			if (clock_display_tick_id > 0U) {
				Source.remove (clock_display_tick_id);
				clock_display_tick_id = 0U;
			}
		}

		void update_clock_labels ()
		{
			var now = new DateTime.now_local ();
			if (clock_time_label != null) clock_time_label.label = now.format ("%H:%M:%S");
			if (clock_date_label != null) clock_date_label.label = now.format ("%A, %e %B %Y");
			if (clock_zone_label != null) clock_zone_label.label = timezone_name (now);
		}

		void start_countdown (int seconds)
		{
			stop_countdown ();
			countdown_seconds = seconds;
			resume_countdown ();
		}

		void resume_countdown ()
		{
			if (countdown_seconds <= 0 || countdown_tick_id > 0U)
				return;
			if (countdown_label != null) countdown_label.label = format_duration (countdown_seconds);
			countdown_tick_id = Timeout.add_seconds (1, () => {
				countdown_seconds--;
				if (countdown_label != null) countdown_label.label = format_duration (int.max (0, countdown_seconds));
				if (countdown_seconds > 0) return true;
				countdown_tick_id = 0U;
				if (countdown_button != null) countdown_button.label = _("Start");
				launch ("notify-send " + Shell.quote (_("Pomodoro finished")) + " "
					+ Shell.quote (_("The current focus or break session has finished.")));
				return false;
			});
		}

		void pause_countdown ()
		{
			if (countdown_tick_id > 0U) {
				Source.remove (countdown_tick_id);
				countdown_tick_id = 0U;
			}
		}

		void stop_countdown ()
		{
			if (countdown_tick_id > 0U) {
				Source.remove (countdown_tick_id);
				countdown_tick_id = 0U;
			}
			countdown_seconds = 0;
			if (countdown_label != null) countdown_label.label = _("Timer");
		}

		void toggle_stopwatch ()
		{
			stopwatch_running = !stopwatch_running;
			if (!stopwatch_running) {
				if (stopwatch_tick_id > 0U) Source.remove (stopwatch_tick_id);
				stopwatch_tick_id = 0U;
				return;
			}
			stopwatch_tick_id = Timeout.add_seconds (1, () => {
				if (!stopwatch_running) { stopwatch_tick_id = 0U; return false; }
				stopwatch_seconds++;
				if (stopwatch_label != null) stopwatch_label.label = format_duration (stopwatch_seconds);
				return true;
			});
		}

		string timezone_name (DateTime now)
		{
			var zone = Environment.get_variable ("TZ");
			return zone != null && zone != "" ? zone : now.format ("%Z · UTC%:z");
		}

		string format_duration (int seconds)
		{
			return "%02d:%02d".printf (seconds / 60, seconds % 60);
		}

		int pomodoro_duration ()
		{
			return pomodoro_mode == 0 ? 25 * 60 : (pomodoro_mode == 1 ? 5 * 60 : 15 * 60);
		}

		delegate void SwitchChanged (bool state);
		Gtk.Widget switch_row (string label, bool state, owned SwitchChanged changed,
			bool sensitive = true)
		{
			var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			row.get_style_context ().add_class ("status-row");
			row.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			var toggle = new Gtk.Switch () { active = state, valign = Gtk.Align.CENTER };
			toggle.sensitive = sensitive;
			toggle.notify["active"].connect (() => changed (toggle.active));
			row.pack_end (toggle, false, false, 0);
			return row;
		}

		Gtk.Widget info_row (string title, string subtitle)
		{
			var row = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			row.get_style_context ().add_class ("status-row");
			row.pack_start (new Gtk.Label (title) { xalign = 0.0f }, false, false, 0);
			var sub = new Gtk.Label (subtitle) { xalign = 0.0f };
			sub.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			row.pack_start (sub, false, false, 0);
			return row;
		}

		void position_over_item ()
		{
			if (current_item == null)
				return;
			var item = controller.position_manager.get_screen_region_for_item (current_item);
			var bar = controller.position_manager.get_screen_background_region ();
			var workarea = active_workarea ();
			int actual_width, actual_height;
			get_size (out actual_width, out actual_height);
			var desired_x = item.x + item.width / 2 - actual_width / 2;
			var min_x = workarea.x + 8;
			var max_x = workarea.x + workarea.width - actual_width - 8;
			var desired_y = bar.y - actual_height - PANEL_GAP;
			var min_y = workarea.y + 8;
			var max_y = workarea.y + workarea.height - actual_height - 8;
			move (int.max (min_x, int.min (max_x, desired_x)),
				int.max (min_y, int.min (max_y, desired_y)));
		}

		Gdk.Rectangle active_workarea ()
		{
			var screen = get_screen ();
			var bar = controller.position_manager.get_screen_background_region ();
			var monitor = screen.get_monitor_at_point (bar.x + bar.width / 2, bar.y + bar.height / 2);
			return screen.get_monitor_workarea (monitor);
		}

		void apply_theme ()
		{
			var color = controller.renderer.theme.FillStartColor;
			var css = ".plank-status-panel { background: transparent; }";
			css += ".plank-status-panel .status-card { background-color: rgb(%d,%d,%d); border: 1px solid rgba(255,255,255,0.10); border-radius: 12px; padding: 7px; }"
				.printf ((int)(color.red*255), (int)(color.green*255), (int)(color.blue*255));
			css += ".plank-status-panel .status-title { padding: 5px 7px; color: white; }";
			css += ".plank-status-panel .status-title-label { font-weight: bold; font-size: 15px; }";
			css += ".plank-status-panel .status-row { color: white; padding: 4px 6px; border-radius: 8px; }";
			css += ".plank-status-panel .status-notice { color: white; background-color: rgba(224,70,70,0.20); border: 1px solid rgba(255,120,120,0.30); border-radius: 8px; padding: 6px 7px; margin: 2px 1px 5px 1px; }";
			css += ".plank-status-panel .status-notice-dismiss { color: white; background: transparent; background-image: none; border: none; box-shadow: none; padding: 2px; }";
			css += ".plank-status-panel .status-notice-dismiss:hover { background-color: rgba(255,255,255,0.12); border-radius: 5px; }";
			css += ".plank-status-panel .status-section-label { color: rgba(255,255,255,0.58); font-size: 10px; font-weight: bold; margin: 4px 6px 0 6px; }";
			css += ".plank-status-panel .status-action-button { color: white; background-color: rgba(255,255,255,0.08); background-image: none; border: none; border-radius: 8px; box-shadow: none; padding: 5px; margin-top: 4px; }";
			css += ".plank-status-panel .bluetooth-device-row { color: white; padding: 7px 6px; border-radius: 9px; background-color: rgba(255,255,255,0.05); margin: 2px 3px; }";
			css += ".plank-status-panel .bluetooth-device-row:hover { background-color: rgba(255,255,255,0.08); }";
			css += ".plank-status-panel .bluetooth-device-action { color: white; background-color: rgba(255,255,255,0.09); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 7px; }";
			css += ".plank-status-panel .bluetooth-device-action:hover { background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .wifi-network-row { color: white; padding: 7px 6px; border-radius: 9px; background-color: rgba(255,255,255,0.05); margin: 2px 3px; }";
			css += ".plank-status-panel .wifi-network-row:hover { background-color: rgba(255,255,255,0.08); }";
			css += ".plank-status-panel .wifi-network-action { color: white; background-color: rgba(255,255,255,0.09); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 7px; }";
			css += ".plank-status-panel .wifi-network-action:hover { background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .wifi-networks-scroll, .plank-status-panel .wifi-networks-list { background: transparent; border: none; box-shadow: none; }";
			css += ".plank-status-panel .wifi-networks-scroll scrollbar { background: transparent; border: none; }";
			css += ".plank-status-panel .wifi-networks-scroll scrollbar slider { min-width: 4px; min-height: 28px; background-color: rgba(255,255,255,0.20); border-radius: 4px; }";
			css += ".plank-status-panel .battery-summary { color: white; padding: 8px 10px; }";
			css += ".plank-status-panel .battery-percentage { color: white; font-size: 34px; font-weight: bold; }";
			css += ".plank-status-panel .battery-metric-row { color: white; padding: 3px 7px; }";
			css += ".plank-status-panel .battery-metric-value { color: rgba(255,255,255,0.72); font-weight: bold; }";
			css += ".plank-status-panel .power-profiles { margin: 2px 5px; }";
			css += ".plank-status-panel .power-profile-button { color: rgba(255,255,255,0.70); background: rgba(255,255,255,0.06); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px; }";
			css += ".plank-status-panel .power-profile-button:checked { color: white; background-color: rgba(115,210,22,0.28); }";
			css += ".plank-status-panel .clock-summary { color: white; padding: 3px 8px 5px 8px; }";
			css += ".plank-status-panel .clock-tabs { margin: 2px 5px 6px 5px; }";
			css += ".plank-status-panel .clock-tabs button { color: rgba(255,255,255,0.65); background: transparent; background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 3px; font-size: 9px; }";
			css += ".plank-status-panel .clock-tabs button:checked { color: white; background-color: rgba(255,255,255,0.13); }";
			css += ".plank-status-panel .clock-page { color: white; padding: 5px 8px; }";
			css += ".plank-status-panel .clock-time { color: white; font-size: 31px; font-weight: bold; }";
			css += ".plank-status-panel .clock-date { color: rgba(255,255,255,0.86); font-weight: bold; }";
			css += ".plank-status-panel .clock-calendar { color: white; padding: 2px; }";
			css += ".plank-status-panel .clock-tools { color: white; margin: 3px 5px; }";
			css += ".plank-status-panel .clock-tools spinbutton { color: white; background-color: rgba(255,255,255,0.07); border: none; border-radius: 7px; }";
			css += ".plank-status-panel .clock-tool-button { color: white; background-color: rgba(255,255,255,0.09); background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px 7px; }";
			css += ".plank-status-panel .clock-tool-button:hover { background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .clock-tool-title { color: rgba(255,255,255,0.72); font-size: 13px; font-weight: bold; }";
			css += ".plank-status-panel .clock-counter { color: white; font-size: 32px; font-weight: bold; }";
			css += ".plank-status-panel .status-footer { padding-top: 4px; }";
			css += ".plank-status-panel .status-icon-toggle { color: rgba(255,255,255,0.65); background: transparent; background-image: none; border: none; border-radius: 7px; box-shadow: none; padding: 5px; }";
			css += ".plank-status-panel .status-icon-toggle:checked { color: white; background-color: rgba(255,255,255,0.14); }";
			css += ".plank-status-panel .modern-volume-bar { margin: 2px 6px 5px 6px; }";
			css += ".plank-status-panel .modern-volume-scale trough { min-height: 36px; background-color: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.08); border-radius: 10px; }";
			css += ".plank-status-panel .modern-volume-scale highlight { background-color: rgba(115,210,22,0.48); border-radius: 9px; }";
			css += ".plank-status-panel .modern-volume-scale slider { min-width: 0; min-height: 0; margin: 0; padding: 0; background: transparent; border: none; box-shadow: none; }";
			css += ".plank-status-panel .modern-volume-bar .status-icon-toggle { color: white; background: transparent; padding: 5px; }";
			css += ".plank-status-panel .modern-volume-value { color: white; font-size: 11px; font-weight: bold; }";
			css += ".plank-status-panel .modern-device-selector { color: white; background: transparent; border: none; box-shadow: none; padding: 0; }";
			css += ".plank-status-panel .modern-device-selector button { color: white; background-color: rgba(255,255,255,0.07); background-image: none; border: 1px solid rgba(255,255,255,0.09); border-radius: 9px; box-shadow: none; padding: 6px 9px; }";
			css += ".plank-status-panel .modern-device-selector button:hover { background-color: rgba(255,255,255,0.11); }";
			css += ".plank-status-panel separator { background-color: rgba(255,255,255,0.10); }";
			css += ".plank-status-panel .status-scroll { background: transparent; border: none; box-shadow: none; }";
			css += ".plank-status-panel scrollbar { background: transparent; border: none; }";
			css += ".plank-status-panel scrollbar slider { min-width: 4px; min-height: 28px; background-color: rgba(255,255,255,0.18); border-radius: 4px; }";
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
			css_provider = new Gtk.CssProvider ();
			try { css_provider.load_from_data (css); } catch (Error e) { warning ("Status panel CSS: %s", e.message); }
			Gtk.StyleContext.add_provider_for_screen (get_screen (), css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}

		static void launch (string command) { try { Process.spawn_command_line_async (command); } catch (SpawnError e) {} }
		static string label_for_kind (StatusIndicatorKind kind) {
			switch (kind) {
			case StatusIndicatorKind.VOLUME: return _("Volume"); case StatusIndicatorKind.BLUETOOTH: return _("Bluetooth");
			case StatusIndicatorKind.WIFI: return _("Wi-Fi"); case StatusIndicatorKind.BATTERY: return _("Battery");
			case StatusIndicatorKind.CLOCK: return _("Time and date"); default: return "";
			}
		}
		static string icon_for_kind (StatusIndicatorKind kind) {
			switch (kind) {
			case StatusIndicatorKind.VOLUME: return "audio-volume-high-symbolic"; case StatusIndicatorKind.BLUETOOTH: return "bluetooth-symbolic";
			case StatusIndicatorKind.WIFI: return "network-wireless-symbolic"; case StatusIndicatorKind.BATTERY: return "battery-good-symbolic";
			case StatusIndicatorKind.CLOCK: return "preferences-system-time-symbolic"; default: return "preferences-system-symbolic";
			}
		}
	}
}
