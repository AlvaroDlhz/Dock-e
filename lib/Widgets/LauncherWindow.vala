//
// Native application launcher window.
//

namespace Plank
{
	public class LauncherWindow : Gtk.Window
	{
		const int PANEL_WIDTH = 580;
		const int PANEL_HEIGHT = 580;
		const int PANEL_MARGIN = 10;
		const int CLOSE_ANIMATION_TIME = 110;
		// Most of the opening happens in its first third, so it still feels
		// immediate. The window takes keyboard input from the very first frame.
		const int OPEN_ANIMATION_TIME = 130;
		// The first rows appear one after another while the window opens
		const int CASCADE_ROWS = 14;
		const int CASCADE_STAGGER = 9;
		const int CASCADE_FADE_TIME = 110;
		// Installing a package touches several desktop files in a row
		const uint REINDEX_DELAY = 750;

		unowned DockController controller;
		Gtk.Entry search_entry;
		Gtk.Button user_avatar_button;
		Gtk.Button dismiss_notice_button;
		Gtk.ListBox result_list;
		Gtk.ScrolledWindow result_scroll;
		Gtk.Label? calculation_status_label;
		StatusNoticeModel notice_model;
		Gtk.Revealer notice_revealer;
		Gtk.Label notice_label;
		ulong notice_changed_id = 0UL;
		// Which applications there are, and how they are ordered and found
		LauncherCatalog catalog;
		// The commands of the user and the saved profiles, offered after a slash
		LauncherCommands custom_commands;
		DockProfiles profiles;
		// Those of them the list shows right now, by what tells them apart
		Gee.HashMap<string, LauncherCommand> listed_commands;
		Gee.ArrayList<AppInfo> visible_results;
		Gee.ArrayList<string> visible_commands;
		// What can be done with the typed text when nothing matches it
		Gee.ArrayList<string> visible_actions;
		string action_query = "";
		// The most used applications lead the complete catalog. They are listed
		// again further down, so each of them needs a second row of its own.
		const int FREQUENT_ROWS = 6;
		int frequent_count = 0;
		Gee.HashMap<AppInfo, Gtk.ListBoxRow> frequent_rows;
		LauncherUsage usage;
		// Rows are expensive to build, so each application keeps its own
		Gee.HashMap<AppInfo, Gtk.ListBoxRow> application_rows;
		// The rows the list is about to show, in their order
		Gee.ArrayList<Gtk.Widget> staged_rows;
		AppInfoMonitor application_monitor;
		uint reindex_timer_id = 0U;
		uint prepare_catalog_id = 0U;
		// Whether the list currently shows the complete, unfiltered catalog
		bool catalog_ready = false;
		bool showing_commands = false;
		bool showing_calculation = false;
		string calculation_result = "";
		LauncherItem? anchor_item;
		WindowTransition transition;
		// The point the window grows out of, which is as near to its button as it gets
		double growth_x = 0.0;
		double growth_y = 0.0;
		uint cascade_tick_id = 0U;
		int64 cascade_start = 0LL;
		// Paints the selection highlight, so it can glide between rows
		ListSelectionGlide selection_glide;
		int panel_x = 0;
		int panel_y = 0;
		bool context_menu_open = false;
		bool context_dialog_open = false;
		Gtk.Window? application_context;
		ApplicationUninstallService uninstall_service;
		Cancellable? uninstall_detection;
		Gee.HashMap<string, string> uninstall_command_cache;
		Gee.HashSet<string> uninstall_detection_pending;

		public LauncherWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			transition = new WindowTransition (this);
			transition.finished.connect ((hidden) => {
				if (hidden)
					controller.renderer.animated_draw ();
			});
			hide.connect (() => {
				stop_cascade ();
				if (anchor_item != null)
					anchor_item.set_menu_active (false);
				// Leave the catalog ready so the next opening has nothing to build
				schedule_prepare_catalog ();
			});
			visible_results = new Gee.ArrayList<AppInfo> ();
			visible_commands = new Gee.ArrayList<string> ();
			visible_actions = new Gee.ArrayList<string> ();
			frequent_rows = new Gee.HashMap<AppInfo, Gtk.ListBoxRow> ();
			usage = new LauncherUsage (controller.config_folder.get_child ("launcher-usage.ini"));
			catalog = new LauncherCatalog (usage);
			custom_commands = new LauncherCommands (
				controller.config_folder.get_child (LauncherCommands.FILE_NAME));
			profiles = new DockProfiles (controller.prefs.settings,
				controller.config_folder.get_child (DockProfiles.FOLDER_NAME));
			listed_commands = new Gee.HashMap<string, LauncherCommand> ();
			application_rows = new Gee.HashMap<AppInfo, Gtk.ListBoxRow> ();
			staged_rows = new Gee.ArrayList<Gtk.Widget> ();
			uninstall_service = new ApplicationUninstallService ();
			uninstall_command_cache = new Gee.HashMap<string, string> ();
			uninstall_detection_pending = new Gee.HashSet<string> ();
			notice_model = new StatusNoticeModel ();
			notice_changed_id = notice_model.changed.connect (sync_notice);
			Accessibility.describe (this, _("Application launcher"));

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
			var rgba_visual = get_screen ().get_rgba_visual ();
			if (rgba_visual != null)
				set_visual (rgba_visual);
			get_style_context ().add_class ("plank-native-launcher");

			var panel = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
			panel.margin = PANEL_MARGIN;
			panel.get_style_context ().add_class ("launcher-panel");
			add (panel);

			var navbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
			navbar.get_style_context ().add_class ("launcher-navbar");
			var user_name = Environment.get_user_name ();
			var user_identity = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			user_identity.get_style_context ().add_class ("launcher-user-identity");
			Accessibility.describe (user_identity, _("Current user: %s").printf (user_name));
			user_avatar_button = new Gtk.Button ();
			user_avatar_button.relief = Gtk.ReliefStyle.NONE;
			user_avatar_button.tooltip_text = _("User settings");
			user_avatar_button.get_style_context ().add_class ("launcher-user-avatar-button");
			Accessibility.describe (user_avatar_button, _("Open user settings"));
			user_avatar_button.add (create_user_avatar ());
			user_avatar_button.clicked.connect (open_user_settings);
			user_identity.pack_start (user_avatar_button, false, false, 0);
			navbar.pack_start (user_identity, false, false, 0);

			var search_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			search_box.valign = Gtk.Align.CENTER;
			search_box.hexpand = true;
			search_box.get_style_context ().add_class ("launcher-search");
			search_entry = new Gtk.Entry ();
			search_entry.placeholder_text = _("Search applications or type / for commands…");
			Accessibility.describe (search_entry, _("Search applications"),
				_("Type to filter the application list"));
			search_entry.has_frame = false;
			search_entry.changed.connect (refresh_results);
			search_entry.focus_in_event.connect (() => {
				search_box.get_style_context ().add_class ("launcher-search-focused");
				return false;
			});
			search_entry.focus_out_event.connect (() => {
				search_box.get_style_context ().remove_class ("launcher-search-focused");
				return false;
			});
			search_box.pack_start (search_entry, true, true, 0);
			navbar.pack_start (search_box, true, true, 0);

			panel.pack_start (navbar, false, false, 0);

			notice_revealer = new Gtk.Revealer ();
			notice_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
			notice_revealer.transition_duration = CLOSE_ANIMATION_TIME;
			var notice = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 7);
			notice.get_style_context ().add_class ("launcher-notice");
			Accessibility.set_role (notice, Atk.Role.ALERT);
			notice.pack_start (new Gtk.Image.from_icon_name ("dialog-warning-symbolic",
				Gtk.IconSize.MENU), false, false, 0);
			notice_label = new Gtk.Label ("") { xalign = 0.0f, wrap = true, max_width_chars = 44 };
			notice.pack_start (notice_label, true, true, 0);
			dismiss_notice_button = new Gtk.Button.from_icon_name ("window-close-symbolic",
				Gtk.IconSize.MENU);
			dismiss_notice_button.tooltip_text = _("Dismiss");
			Accessibility.describe (dismiss_notice_button, _("Dismiss error"));
			dismiss_notice_button.get_style_context ().add_class ("launcher-notice-dismiss");
			dismiss_notice_button.clicked.connect (() => notice_model.dismiss ());
			notice.pack_end (dismiss_notice_button, false, false, 0);
			notice_revealer.add (notice);
			panel.pack_start (notice_revealer, false, false, 0);

			result_list = new Gtk.ListBox ();
			Accessibility.describe (result_list, _("Application results"));
			result_list.selection_mode = Gtk.SelectionMode.SINGLE;
			result_list.activate_on_single_click = true;
			selection_glide = new ListSelectionGlide (result_list);
			result_list.row_selected.connect ((row) => {
				if (row == null)
					return;
				Idle.add (() => {
					if (row.get_parent () == result_list)
						scroll_row_into_view (row);
					return false;
				});
			});
			result_list.row_activated.connect ((row) => activate_row (row));
			result_list.set_header_func ((row, before) => {
				var index = row.get_index ();
				if (search_entry.text.strip () != "" || index < 0 || index >= visible_results.size) {
					row.set_header (null);
					return;
				}
				if (index < frequent_count) {
					row.set_header (index == 0 ? create_alphabet_header (_("Frequent")) : null);
					return;
				}
				var initial = LauncherCatalog.alphabet_initial (visible_results[index]);
				if (index > frequent_count && LauncherCatalog.alphabet_initial (visible_results[index - 1]) == initial) {
					row.set_header (null);
					return;
				}
				row.set_header (create_alphabet_header (initial));
			});
			result_list.button_press_event.connect ((event) => {
				Accessibility.set_keyboard_navigation (this, false);
				if (event.button != 3U)
					return false;
				var row = result_list.get_row_at_y ((int) event.y);
				if (row == null || row.get_index () < 0 || row.get_index () >= visible_results.size)
					return false;
				result_list.select_row (row);
				show_application_context_menu (visible_results[row.get_index ()],
					event.x_root, event.y_root);
				return true;
			});
			result_scroll = new Gtk.ScrolledWindow (null, null);
			result_scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			result_scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
			result_scroll.overlay_scrolling = true;
			result_scroll.get_style_context ().add_class ("launcher-results-scroll");
			result_scroll.add (result_list);
			panel.pack_start (result_scroll, true, true, 0);

			key_press_event.connect (handle_key_press);
			button_press_event.connect (() => {
				Accessibility.set_keyboard_navigation (this, false);
				return false;
			});
			focus_out_event.connect (() => {
				if (!context_menu_open)
					hide_animated ();
				return false;
			});
			index_applications ();
			sync_notice ();
			panel.show_all ();

			application_monitor = AppInfoMonitor.get ();
			application_monitor.changed.connect (schedule_reindex);
			schedule_prepare_catalog ();
		}

		~LauncherWindow ()
		{
			if (uninstall_detection != null)
				uninstall_detection.cancel ();
			if (notice_changed_id > 0UL)
				SignalHandler.disconnect (notice_model, notice_changed_id);
			if (reindex_timer_id > 0U)
				Source.remove (reindex_timer_id);
			if (prepare_catalog_id > 0U)
				Source.remove (prepare_catalog_id);
			application_monitor.changed.disconnect (schedule_reindex);
		}

		Gtk.Widget create_user_avatar ()
		{
			const int avatar_size = 36;
			const double corner_radius = 5.0;
			var fallback = new Gtk.Image.from_icon_name ("avatar-default-symbolic", Gtk.IconSize.BUTTON);
			fallback.pixel_size = 27;
			fallback.get_style_context ().add_class ("launcher-user-avatar-fallback");

			var home = Environment.get_home_dir ();
			var user_name = Environment.get_user_name ();
			string[] candidates = {
				Path.build_filename (home, ".face"),
				Path.build_filename (home, ".face.icon"),
				Path.build_filename ("/var/lib/AccountsService/icons", user_name)
			};
			foreach (unowned string path in candidates) {
				if (!FileUtils.test (path, FileTest.IS_REGULAR))
					continue;
				try {
					var source = new Gdk.Pixbuf.from_file (path);
					var side = int.min (source.width, source.height);
					var square = new Gdk.Pixbuf.subpixbuf (source,
						(source.width - side) / 2, (source.height - side) / 2, side, side);
					var scaled = square.scale_simple (avatar_size, avatar_size,
						Gdk.InterpType.BILINEAR);
					if (scaled == null)
						continue;
					var surface = new Cairo.ImageSurface (Cairo.Format.ARGB32,
						avatar_size, avatar_size);
					var cr = new Cairo.Context (surface);
					cr.set_operator (Cairo.Operator.SOURCE);
					cr.set_source_rgba (0.0, 0.0, 0.0, 0.0);
					cr.paint ();
					cr.set_operator (Cairo.Operator.OVER);
					cr.new_sub_path ();
					cr.arc (avatar_size - corner_radius, corner_radius,
						corner_radius, -Math.PI / 2.0, 0.0);
					cr.arc (avatar_size - corner_radius, avatar_size - corner_radius,
						corner_radius, 0.0, Math.PI / 2.0);
					cr.arc (corner_radius, avatar_size - corner_radius,
						corner_radius, Math.PI / 2.0, Math.PI);
					cr.arc (corner_radius, corner_radius,
						corner_radius, Math.PI, 3.0 * Math.PI / 2.0);
					cr.close_path ();
					cr.clip ();
					Gdk.cairo_set_source_pixbuf (cr, scaled, 0.0, 0.0);
					cr.paint ();
					var avatar = new Gtk.Image.from_pixbuf (Gdk.pixbuf_get_from_surface (
						surface, 0, 0, avatar_size, avatar_size));
					avatar.get_style_context ().add_class ("launcher-user-avatar");
					return avatar;
				} catch (Error e) {
					warning ("Unable to load user avatar '%s': %s", path, e.message);
				}
			}

			return fallback;
		}

		void open_user_settings ()
		{
			var argv = SessionActions.command_for_session ("user-settings");
			if (argv == null) {
				warning ("Unable to open user settings: no supported user settings application was found");
				show_launcher_error (_("User settings are not available on this system."));
				return;
			}

			try {
				Pid pid;
				Process.spawn_async (null, argv, null, SpawnFlags.SEARCH_PATH, null, out pid);
				notice_model.dismiss ();
				hide_animated ();
			} catch (SpawnError e) {
				warning ("Unable to open user settings: %s", e.message);
				show_launcher_error (_("User settings could not be opened. Please try again."));
			}
		}

		const string[] POWER_ACTIONS = { "preferences", "lock", "suspend", "logout", "restart", "poweroff" };

		string power_action_label (string action)
		{
			switch (action) {
			case "preferences": return _("Dock-E Preferences");
			case "lock": return _("Lock");
			case "suspend": return _("Suspend");
			case "logout": return _("Log out");
			case "restart": return _("Restart");
			case "poweroff": return _("Power off");
			default: return action;
			}
		}

		string power_action_aliases (string action)
		{
			switch (action) {
			case "preferences": return "preferences preferencias";
			case "lock": return "bloquear lock";
			case "suspend": return "dormir suspender suspend";
			case "logout": return "cerrar-sesion salir logout";
			case "restart": return "reiniciar restart reboot";
			case "poweroff": return "apagar poweroff halt";
			default: return "";
			}
		}

		Gtk.ListBoxRow create_power_command_row (string action)
		{
			var row = new Gtk.ListBoxRow ();
			row.get_style_context ().add_class ("launcher-result");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
			box.margin_left = box.margin_right = 12;
			box.margin_top = box.margin_bottom = 9;
			string icon_name;
			switch (action) {
			case "preferences": icon_name = "preferences-system-symbolic"; break;
			case "lock": icon_name = "system-lock-screen-symbolic"; break;
			case "suspend": icon_name = "media-playback-pause-symbolic"; break;
			case "logout": icon_name = "system-log-out-symbolic"; break;
			case "restart": icon_name = "system-reboot-symbolic"; break;
			default: icon_name = "system-shutdown-symbolic"; break;
			}
			var icon = new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.DIALOG);
			icon.pixel_size = 30;
			box.pack_start (icon, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			labels.pack_start (new Gtk.Label (power_action_label (action)) { xalign = 0.0f },
				false, false, 0);
			var aliases = power_action_aliases (action).split (" ");
			var command_hint = new Gee.ArrayList<string> ();
			if (action == "preferences")
				command_hint.add ("/preferences");
			else
				foreach (unowned string alias in aliases)
					command_hint.add ("/" + alias);
			var hint = new Gtk.Label (string.joinv (" · ", command_hint.to_array ())) {
				xalign = 0.0f
			};
			hint.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (hint, false, false, 0);
			box.pack_start (labels, true, true, 0);
			var enter_hint = new Gtk.Label ("↵");
			enter_hint.get_style_context ().add_class ("launcher-enter");
			box.pack_end (enter_hint, false, false, 0);
			row.add (box);
			return row;
		}

		const string PROFILE_PREFIX = "profile:";
		const string PROFILE_SAVE_PREFIX = "profile-save:";
		// What is typed after the slash to switch to a profile, and to save one
		const string[] PROFILE_WORDS = { "perfil", "profile" };
		const string[] PROFILE_SAVE_WORDS = { "guardar-perfil", "save-profile" };

		/**
		 * The commands which are not built in: those the user wrote down, and
		 * one for each saved profile.
		 */
		Gee.ArrayList<LauncherCommand> own_commands ()
		{
			var result = new Gee.ArrayList<LauncherCommand> ();
			result.add_all (custom_commands.commands);
			foreach (unowned string name in profiles.list ()) {
				string[] words = {};
				foreach (unowned string word in PROFILE_WORDS)
					words += "%s %s".printf (word, LauncherSearch.normalize (name));
				result.add (new LauncherCommand (PROFILE_PREFIX + name,
					_("Switch to the profile “%s”").printf (name),
					"preferences-desktop-theme-symbolic", words, name));
			}
			return result;
		}

		/**
		 * The command which saves the preferences as a profile, if that is
		 * what is being typed.
		 *
		 * @param typed_command what follows the slash, as it was typed
		 */
		LauncherCommand? profile_save_command (string typed_command)
		{
			foreach (unowned string word in PROFILE_SAVE_WORDS) {
				if (!typed_command.down ().has_prefix (word))
					continue;
				var name = typed_command.substring (word.length).strip ();
				string[] words = {};
				foreach (unowned string save_word in PROFILE_SAVE_WORDS)
					words += "%s %s".printf (save_word, name != "" ? name : _("name"));
				return new LauncherCommand (PROFILE_SAVE_PREFIX + name,
					name != "" ? _("Save these preferences as the profile “%s”").printf (name)
						: _("Save these preferences as a profile"),
					"document-save-symbolic", words, name);
			}
			return null;
		}

		void list_command (LauncherCommand command)
		{
			if (listed_commands.has_key (command.id))
				return;
			listed_commands[command.id] = command;
			visible_commands.add (command.id);
			staged_rows.add (create_command_row (command));
		}

		Gtk.ListBoxRow create_command_row (LauncherCommand command)
		{
			var row = new Gtk.ListBoxRow ();
			row.get_style_context ().add_class ("launcher-result");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
			box.margin_left = box.margin_right = 12;
			box.margin_top = box.margin_bottom = 9;
			var icon = new Gtk.Image.from_icon_name (command.icon, Gtk.IconSize.DIALOG);
			icon.pixel_size = 30;
			box.pack_start (icon, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			var name = new Gtk.Label (command.name) { xalign = 0.0f };
			name.ellipsize = Pango.EllipsizeMode.END;
			labels.pack_start (name, false, false, 0);
			var hint = new Gtk.Label (command.hint ()) { xalign = 0.0f };
			hint.ellipsize = Pango.EllipsizeMode.END;
			hint.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (hint, false, false, 0);
			box.pack_start (labels, true, true, 0);
			var enter_hint = new Gtk.Label ("↵");
			enter_hint.get_style_context ().add_class ("launcher-enter");
			box.pack_end (enter_hint, false, false, 0);
			row.add (box);
			return row;
		}

		void run_command (LauncherCommand command)
		{
			try {
				if (command.id.has_prefix (PROFILE_SAVE_PREFIX)) {
					if (!DockProfiles.is_valid_name (command.argument)) {
						show_launcher_error (_("Type a name after the command, using letters, digits, spaces or dashes."));
						return;
					}
					profiles.save (command.argument);
				} else if (command.id.has_prefix (PROFILE_PREFIX)) {
					profiles.apply (command.argument);
				} else {
					Process.spawn_command_line_async (command.argument);
				}
				notice_model.dismiss ();
				hide_animated ();
			} catch (Error e) {
				warning ("Unable to run the command '%s': %s", command.id, e.message);
				show_launcher_error (_("“%s” could not be done: %s").printf (command.name, e.message));
			}
		}

		void run_session_action (string action)
		{
			var argv = SessionActions.command_for_session (action);
			if (argv == null) {
				warning ("Unable to run session action '%s': nothing on this system can do it", action);
				show_launcher_error (_("This system action is not available on this desktop."));
				return;
			}

			try {
				Pid pid;
				Process.spawn_async (null, argv, null, SpawnFlags.SEARCH_PATH, null, out pid);
				notice_model.dismiss ();
			} catch (SpawnError e) {
				warning ("Unable to run session action: %s", e.message);
				show_launcher_error (_("The selected system action could not be started. Please try again."));
			}
		}

		void show_launcher_error (string user_message)
		{
			notice_model.show_error (user_message);
			transition.jump_to (1.0);
			show ();
			position_centered ();
			present ();
		}

		void sync_notice ()
		{
			notice_label.label = notice_model.message;
			notice_revealer.reveal_child = notice_model.visible;
		}

		void schedule_reindex ()
		{
			if (reindex_timer_id > 0U)
				Source.remove (reindex_timer_id);
			reindex_timer_id = Timeout.add (REINDEX_DELAY, () => {
				reindex_timer_id = 0U;
				index_applications ();
				// Do not swap the list under the user; it is rebuilt once hidden
				if (!visible)
					schedule_prepare_catalog ();
				return false;
			});
		}

		void schedule_prepare_catalog ()
		{
			if (prepare_catalog_id > 0U)
				return;
			prepare_catalog_id = Idle.add_full (Priority.LOW, () => {
				prepare_catalog_id = 0U;
				if (!visible)
					prepare_catalog ();
				return false;
			});
		}

		/**
		 * Makes sure the list shows the complete catalog, scrolled to its top.
		 * This is a no-op if it already does.
		 */
		void prepare_catalog ()
		{
			apply_theme ();
			if (search_entry.text != "")
				search_entry.text = "";
			if (!catalog_ready)
				refresh_results ();
			var first_row = result_list.get_row_at_index (0);
			if (first_row != null && first_row.selectable)
				result_list.select_row (first_row);
			result_scroll.get_vadjustment ().value = 0.0;
		}

		void index_applications ()
		{
			catalog.index ();
			// The rows belong to applications which may be gone now
			application_rows.clear ();
			frequent_rows.clear ();
			catalog_ready = false;
		}

		public void toggle (LauncherItem item)
		{
			if (visible) {
				hide_animated ();
				return;
			}
			show_for_item (item);
		}

		public void toggle_global ()
		{
			if (visible) {
				hide_animated ();
				return;
			}

			foreach (unowned DockItem item in controller.VisibleItems) {
				var launcher_item = item as LauncherItem;
				if (launcher_item != null) {
					show_for_item (launcher_item);
					return;
				}
			}
			warning ("Unable to open the launcher: its dock item is not available");
		}

		public void dismiss ()
		{
			dismiss_application_context ();
			hide_animated ();
		}

		public void dismiss_immediately ()
		{
			dismiss_application_context ();
			transition.jump_to (0.0);
			if (visible)
				hide ();
			controller.renderer.animated_draw ();
		}

		public void dismiss_application_context ()
		{
			if (application_context != null && application_context.visible)
				application_context.hide ();
		}

		public void show_for_item (LauncherItem item)
		{
			controller.workspace_previews.dismiss ();
			Accessibility.set_keyboard_navigation (this, false);
			if (anchor_item != null && anchor_item != item)
				anchor_item.set_menu_active (false);
			anchor_item = item;
			anchor_item.set_menu_active (true);
			prepare_catalog ();
			transition.jump_to (0.0);
			show ();
			controller.renderer.animated_draw ();
			present ();
			search_entry.grab_focus ();
			Idle.add (() => {
				position_centered ();
				transition.animate_to (1.0,
					Motion.duration (controller.prefs, OPEN_ANIMATION_TIME), false, true);
				start_cascade ();
				return false;
			});
		}

		void refresh_results ()
		{
			stop_cascade ();
			// The rows are replaced, so there is nothing to glide from
			selection_glide.snap ();
			// Rows are kept and reused. One taken out while selected would still
			// claim to be selected when it returns, and the list would then
			// refuse to select it again, leaving nothing selected at all.
			result_list.unselect_all ();
			// What the list is to show is collected first and compared with
			// what it shows already, see finish_refresh_results ()
			staged_rows.clear ();
			visible_results.clear ();
			visible_commands.clear ();
			listed_commands.clear ();
			visible_actions.clear ();
			frequent_count = 0;
			showing_calculation = false;
			calculation_result = "";
			calculation_status_label = null;

			var typed = search_entry.text.strip ();
			var query = LauncherSearch.normalize (typed);
			action_query = typed;
			catalog_ready = query == "";
			showing_commands = query.has_prefix ("/");
			if (showing_commands) {
				var command_query = query.substring (1).strip ();
				foreach (unowned string action in POWER_ACTIONS) {
					if (!SessionActions.is_listed (action, controller.prefs.ShowSessionActions))
						continue;
					if (command_query == ""
						|| LauncherSearch.score (power_action_search_text (action), command_query) >= 0) {
						visible_commands.add (action);
						staged_rows.add (create_power_command_row (action));
					}
				}
				// What is typed keeps its case, a profile is named as it is written
				var save_command = profile_save_command (typed.substring (1).strip ());
				if (save_command != null)
					list_command (save_command);
				foreach (var command in own_commands ()) {
					if (command_query == ""
						|| LauncherSearch.score (command.search_text (), command_query) >= 0)
						list_command (command);
				}
				if (save_command == null && command_query == "")
					list_command (profile_save_command (PROFILE_SAVE_WORDS[0]));
				if (visible_commands.size == 0)
					staged_rows.add (create_empty_row (_("No matching commands")));
				finish_refresh_results ();
				return;
			}

			double result;
			if (CalculatorService.evaluate (typed.down (), out result)) {
				showing_calculation = true;
				calculation_result = result == 0.0 ? "0" : result.to_string ();
				staged_rows.add (create_calculation_row (typed, calculation_result));
				finish_refresh_results ();
				return;
			}

			if (query == "") {
				// The applications opened most lead the catalog. The list asks
				// for the header of a row as soon as it is added, so how many
				// of them are frequent has to be known before that
				var frequent = catalog.frequent (FREQUENT_ROWS);
				frequent_count = frequent.size;
				foreach (var app in frequent) {
					Gtk.ListBoxRow? row = frequent_rows[app];
					if (row == null) {
						row = create_result_row (app);
						frequent_rows[app] = row;
					}
					visible_results.add (app);
					staged_rows.add (row);
				}

				foreach (var app in catalog.applications) {
					visible_results.add (app);
					staged_rows.add (get_application_row (app, query));
				}
				finish_refresh_results ();
				return;
			}

			foreach (var app in catalog.search (query)) {
				visible_results.add (app);
				staged_rows.add (get_application_row (app, query));
			}

			// Session commands are found by their name too, without the slash
			if (query.char_count () >= 2) {
				foreach (unowned string action in POWER_ACTIONS) {
					if (!SessionActions.is_listed (action, controller.prefs.ShowSessionActions))
						continue;
					if (LauncherSearch.matches_clearly (power_action_search_text (action), query)) {
						visible_commands.add (action);
						staged_rows.add (create_power_command_row (action));
					}
				}
				foreach (var command in own_commands ())
					if (LauncherSearch.matches_clearly (command.search_text (), query))
						list_command (command);
			}

			// Nothing to open, so offer what else can be done with the text
			if (visible_results.size == 0 && visible_commands.size == 0) {
				var words = typed.split (" ");
				var program = words.length > 0 ? words[0] : "";
				if (program != "" && Environment.find_program_in_path (program) != null) {
					visible_actions.add ("run");
					staged_rows.add (create_action_row ("utilities-terminal-symbolic",
						_("Run “%s”").printf (typed), _("Command")));
				}
				visible_actions.add ("web");
				staged_rows.add (create_action_row ("system-search-symbolic",
					_("Search the web for “%s”").printf (typed), "DuckDuckGo"));
			}

			finish_refresh_results ();
		}

		/**
		 * The row of an application in the catalog, with the letters of its
		 * name marked which the typed text matched.
		 */
		Gtk.ListBoxRow get_application_row (AppInfo app, string query)
		{
			Gtk.ListBoxRow? row = application_rows[app];
			if (row == null) {
				row = create_result_row (app);
				application_rows[app] = row;
			}
			unowned Gtk.Label? title = row.get_data<Gtk.Label> ("launcher-title");
			if (title != null)
				title.set_markup (LauncherSearch.highlight (app.get_display_name (), query));
			return row;
		}

		string power_action_search_text (string action)
		{
			return LauncherSearch.normalize ("%s %s".printf (power_action_label (action),
				power_action_aliases (action)));
		}

		Gtk.ListBoxRow create_action_row (string icon_name, string title, string hint)
		{
			var row = new Gtk.ListBoxRow ();
			row.get_style_context ().add_class ("launcher-result");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
			box.margin_left = box.margin_right = 12;
			box.margin_top = box.margin_bottom = 9;
			var icon = new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.DIALOG);
			icon.pixel_size = 30;
			box.pack_start (icon, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			var title_label = new Gtk.Label (title) { xalign = 0.0f };
			title_label.ellipsize = Pango.EllipsizeMode.END;
			title_label.max_width_chars = 40;
			labels.pack_start (title_label, false, false, 0);
			var hint_label = new Gtk.Label (hint) { xalign = 0.0f };
			hint_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (hint_label, false, false, 0);
			box.pack_start (labels, true, true, 0);
			var enter_hint = new Gtk.Label ("↵");
			enter_hint.get_style_context ().add_class ("launcher-enter");
			box.pack_end (enter_hint, false, false, 0);
			row.add (box);
			return row;
		}

		void run_action (string action)
		{
			try {
				if (action == "run")
					Process.spawn_command_line_async (action_query);
				else
					AppInfo.launch_default_for_uri ("https://duckduckgo.com/?q="
						+ Uri.escape_string (action_query, null, false), null);
				notice_model.dismiss ();
				hide_animated ();
			} catch (Error e) {
				warning ("Unable to run '%s' for '%s': %s", action, action_query, e.message);
				show_launcher_error (_("That could not be started. Please try again."));
			}
		}

		Gtk.ListBoxRow create_calculation_row (string expression, string result)
		{
			var row = new Gtk.ListBoxRow ();
			Accessibility.describe (row, _("Calculator result: %s").printf (result),
				_("Press Enter to copy the result"));
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
			box.margin_left = box.margin_right = 12;
			box.margin_top = box.margin_bottom = 9;
			var icon = new Gtk.Image.from_icon_name ("accessories-calculator-symbolic",
				Gtk.IconSize.DIALOG);
			icon.pixel_size = 36;
			box.pack_start (icon, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			var expression_label = new Gtk.Label (expression) { xalign = 0.0f };
			expression_label.ellipsize = Pango.EllipsizeMode.END;
			expression_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (expression_label, false, false, 0);
			var result_label = new Gtk.Label (result) { xalign = 0.0f };
			result_label.get_style_context ().add_class ("launcher-calculation-result");
			labels.pack_start (result_label, false, false, 0);
			box.pack_start (labels, true, true, 0);

			calculation_status_label = new Gtk.Label (_("Enter to copy"));
			calculation_status_label.get_style_context ().add_class ("launcher-calculation-status");
			box.pack_end (calculation_status_label, false, false, 0);
			row.add (box);
			return row;
		}

		Gtk.ListBoxRow create_empty_row (string message)
		{
			var empty_row = new Gtk.ListBoxRow () { selectable = false, activatable = false };
			empty_row.get_style_context ().add_class ("launcher-empty");
			var empty_label = new Gtk.Label (message);
			empty_label.margin = 24;
			empty_row.add (empty_label);
			return empty_row;
		}

		void finish_refresh_results ()
		{
			// Typing one more letter often leaves the best matches where they
			// were. Taking a row out and putting it back makes the list work
			// out its styles and sizes again, so the rows which lead both the
			// old and the new list simply stay.
			var current = result_list.get_children ();
			var kept = 0;
			unowned List<weak Gtk.Widget>? link = current;
			while (link != null && kept < staged_rows.size && link.data == staged_rows[kept]) {
				kept++;
				link = link.next;
			}
			for (; link != null; link = link.next)
				result_list.remove (link.data);
			for (var i = kept; i < staged_rows.size; i++)
				result_list.add (staged_rows[i]);
			staged_rows.clear ();

			// Headers depend on the whole list, which is only complete now
			result_list.invalidate_headers ();
			result_list.show_all ();
			var first_row = result_list.get_row_at_index (0);
			if (first_row != null && first_row.selectable)
				result_list.select_row (first_row);
			if (visible)
				Idle.add (() => { position_centered (); return false; });
		}

		void scroll_row_into_view (Gtk.ListBoxRow row)
		{
			int row_y;
			if (!row.translate_coordinates (result_list, 0, 0, null, out row_y))
				return;

			var adjustment = result_scroll.get_vadjustment ();
			var row_top = (double) row_y;
			// A row leading its group is shown together with the group's header
			unowned Gtk.Widget? header = row.get_header ();
			if (header != null && header.visible) {
				int header_y;
				if (header.translate_coordinates (result_list, 0, 0, null, out header_y))
					row_top = double.min (row_top, header_y - header.margin_top);
			}
			var row_bottom = (double) row_y + row.get_allocated_height ();
			if (row_top < adjustment.value)
				adjustment.value = row_top;
			else if (row_bottom > adjustment.value + adjustment.page_size)
				adjustment.value = row_bottom - adjustment.page_size;
		}

		Gtk.ListBoxRow create_result_row (AppInfo app)
		{
			var row = new Gtk.ListBoxRow ();
			row.get_style_context ().add_class ("launcher-result");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 11);
			box.margin_left = box.margin_right = 12;
			box.margin_top = box.margin_bottom = 8;
			Gtk.Image icon;
			if (app.get_icon () != null)
				icon = new Gtk.Image.from_gicon (app.get_icon (), Gtk.IconSize.DIALOG);
			else
				icon = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.DIALOG);
			icon.pixel_size = 36;
			box.pack_start (icon, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			var title = new Gtk.Label (app.get_display_name ()) { xalign = 0.0f };
			title.get_style_context ().add_class ("launcher-result-title");
			row.set_data<Gtk.Label> ("launcher-title", title);
			title.ellipsize = Pango.EllipsizeMode.END;
			title.max_width_chars = 34;
			labels.pack_start (title, false, false, 0);
			var description = new Gtk.Label (app.get_description () ?? app.get_executable ()) { xalign = 0.0f };
			description.ellipsize = Pango.EllipsizeMode.END;
			description.max_width_chars = 34;
			description.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			labels.pack_start (description, false, false, 0);

			box.pack_start (labels, true, true, 0);
			var enter_hint = new Gtk.Label ("↵");
			enter_hint.get_style_context ().add_class ("launcher-enter");
			box.pack_start (enter_hint, false, false, 0);
			var more_button = new Gtk.Button.from_icon_name ("view-more-symbolic",
				Gtk.IconSize.BUTTON);
			more_button.relief = Gtk.ReliefStyle.NONE;
			more_button.tooltip_text = _("More options");
			more_button.get_style_context ().add_class ("launcher-more-button");
			Accessibility.describe (more_button, _("More options for %s")
				.printf (app.get_display_name ()));
			more_button.clicked.connect (() => {
				int root_x = 0, root_y = 0;
				var window = more_button.get_window ();
				if (window == null)
					return;
				window.get_origin (out root_x, out root_y);
				Gtk.Allocation allocation;
				more_button.get_allocation (out allocation);
				show_application_context_menu (app,
					root_x + allocation.x + allocation.width / 2,
					root_y + allocation.y + allocation.height / 2);
			});
			box.pack_end (more_button, false, false, 0);
			row.add (box);
			return row;
		}

		string build_launch_command (AppInfo app)
		{
			string command = app.get_commandline () ?? "";
			if (command.strip () == "")
				command = app.get_executable () ?? "";
			if (command.strip () == "")
				return "";
			try {
				string[] argv;
				Shell.parse_argv (command, out argv);
				var parts = new Gee.ArrayList<string> ();
				foreach (unowned string argument in argv) {
					if (argument == "" || argument.contains ("%"))
						continue;
					parts.add (Shell.quote (argument));
				}
				if (parts.size > 0)
					return string.joinv (" ", parts.to_array ());
			} catch (ShellError e) {
				debug ("Unable to parse launch command '%s': %s", command, e.message);
			}
			return command.strip ();
		}

		string build_kill_command (AppInfo app)
		{
			var launch = build_launch_command (app);
			if (launch == "")
				return "";
			string[] argv;
			try {
				Shell.parse_argv (launch, out argv);
			} catch (ShellError e) {
				return "pkill -x %s".printf (Shell.quote (Path.get_basename (app.get_executable () ?? "")));
			}
			if (argv.length == 0)
				return "";
			var binary = Path.get_basename (argv[0]);
			var app_id = app.get_id () ?? "";
			if (app_id.has_suffix (".desktop"))
				app_id = app_id.substring (0, app_id.length - 8);
			if (binary == "flatpak" && argv.length >= 3 && argv[1] == "run") {
				var id = app_id != "" ? app_id : argv[2];
				return "flatpak kill %s".printf (Shell.quote (id));
			}
			if (binary == "snap" && argv.length >= 3 && argv[1] == "run") {
				var id = app_id != "" ? app_id : argv[2];
				return "snap stop %s".printf (Shell.quote (id));
			}
			return "pkill -x %s".printf (Shell.quote (binary));
		}

		string build_restart_command (AppInfo app)
		{
			var launch = build_launch_command (app);
			if (launch == "")
				return "";
			var kill = build_kill_command (app);
			if (kill == "")
				return launch;
			return "%s; %s".printf (kill, launch);
		}

		string build_uninstall_command (UninstallTarget target)
		{
			var parts = new Gee.ArrayList<string> ();
			foreach (unowned string argument in target.argv)
				parts.add (Shell.quote (argument));
			return string.joinv (" ", parts.to_array ());
		}

		string app_command_key (AppInfo app)
		{
			var id = app.get_id ();
			if (id != null && id != "")
				return id;
			var executable = app.get_executable ();
			if (executable != null && executable != "")
				return executable;
			return app.get_display_name ();
		}

		void copy_uninstall_command (AppInfo app, Gtk.Label status)
		{
			var key = app_command_key (app);
			if (uninstall_command_cache.has_key (key)) {
				copy_command (uninstall_command_cache[key], status);
				return;
			}
			if (uninstall_detection_pending.contains (key)) {
				set_command_status (status, _("Detecting…"), false);
				return;
			}
			uninstall_detection_pending.add (key);
			set_command_status (status, _("Detecting…"), false);
			var desktop = (app as DesktopAppInfo)?.get_filename ();
			uninstall_service.detect.begin (app.get_id () ?? "", app.get_executable () ?? "",
				desktop, null, (obj, result) => {
					uninstall_detection_pending.remove (key);
					UninstallTarget? target = null;
					try {
						target = uninstall_service.detect.end (result);
					} catch (Error e) {
						debug ("Unable to detect uninstall command: %s", e.message);
					}
					if (target == null) {
						set_command_status (status, _("Unavailable"), true);
						return;
					}
					var command = build_uninstall_command (target);
					uninstall_command_cache[key] = command;
					copy_command (command, status);
				});
		}

		void copy_command (string command, Gtk.Label status)
		{
			if (command.strip () == "")
				return;
			var clipboard = Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD);
			clipboard.set_text (command, -1);
			clipboard.store ();
			set_command_status (status, _("Copied"), true);
		}

		void set_command_status (Gtk.Label status, string text, bool auto_hide)
		{
			status.label = text;
			status.visible = true;
			if (auto_hide)
				Timeout.add (1600, () => {
					status.visible = false;
					return false;
				});
		}

		void show_application_context_menu (AppInfo app, double root_x, double root_y)
		{
			if (uninstall_detection != null)
				uninstall_detection.cancel ();
			uninstall_detection = new Cancellable ();
			var detection = uninstall_detection;
			if (application_context != null)
				application_context.destroy ();
			var context = new Gtk.Window (Gtk.WindowType.TOPLEVEL);
			application_context = context;
			context.app_paintable = true;
			var rgba_visual = context.get_screen ().get_rgba_visual ();
			if (rgba_visual != null)
				context.set_visual (rgba_visual);
			context.decorated = false;
			context.resizable = false;
			context.skip_taskbar_hint = true;
			context.skip_pager_hint = true;
			context.set_keep_above (true);
			context.transient_for = this;
			context.type_hint = Gdk.WindowTypeHint.DIALOG;
			context.get_style_context ().add_class ("launcher-app-context");
			Accessibility.set_keyboard_navigation (context, true);

			var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			card.margin = ContextMenuStyle.PADDING + 1;
			context.add (card);
			var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			header.get_style_context ().add_class ("app-context-header");
			Gtk.Image app_icon;
			if (app.get_icon () != null)
				app_icon = new Gtk.Image.from_gicon (app.get_icon (), Gtk.IconSize.DIALOG);
			else
				app_icon = new Gtk.Image.from_icon_name ("application-x-executable", Gtk.IconSize.DIALOG);
			app_icon.pixel_size = 32;
			header.pack_start (app_icon, false, false, 0);
			var heading = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			var name = new Gtk.Label (app.get_display_name ()) { xalign = 0.0f };
			name.get_style_context ().add_class ("app-context-title");
			heading.pack_start (name, false, false, 0);
			var origin = new Gtk.Label (_("Checking installation source…")) { xalign = 0.0f };
			origin.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
			heading.pack_start (origin, false, false, 0);
			header.pack_start (heading, true, true, 0);
			card.pack_start (header, false, false, 0);
			card.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 2);

			card.pack_start (context_action_button (_("Open"), "media-playback-start-symbolic", () => {
				try {
					app.launch (null, null);
					notice_model.dismiss ();
					context.hide ();
					hide_animated ();
				} catch (Error e) {
					warning ("Unable to launch app: %s", e.message);
					context.hide ();
					show_launcher_error (_("The application could not be opened. Check that it is still installed and try again."));
				}
			}), false, false, 0);

			var command_status = new Gtk.Label ("") { xalign = 0.0f };
			command_status.get_style_context ().add_class ("launcher-command-status");
			command_status.visible = false;
			var launch_command = build_launch_command (app);
			var restart_command = build_restart_command (app);
			var kill_command = build_kill_command (app);
			// One row copies any of the commands, instead of a row for each
			var copy_caption = new Gtk.Label (_("Copy command")) { xalign = 0.0f };
			copy_caption.get_style_context ().add_class ("app-context-caption");
			card.pack_start (copy_caption, false, false, 0);
			var copy_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
			copy_row.homogeneous = true;
			copy_row.get_style_context ().add_class ("app-context-chips");
			var copy_launch = context_chip_button (_("Open"), _("Copy launch command"),
				() => copy_command (launch_command, command_status));
			copy_launch.sensitive = launch_command != "";
			copy_row.pack_start (copy_launch, true, true, 0);
			var copy_restart = context_chip_button (_("Restart"), _("Copy restart command"),
				() => copy_command (restart_command, command_status));
			copy_restart.sensitive = restart_command != "";
			copy_row.pack_start (copy_restart, true, true, 0);
			var copy_kill = context_chip_button (_("Terminate"), _("Copy terminate command"),
				() => copy_command (kill_command, command_status));
			copy_kill.sensitive = kill_command != "";
			copy_row.pack_start (copy_kill, true, true, 0);
			copy_row.pack_start (context_chip_button (_("Uninstall"), _("Copy uninstall command"),
				() => copy_uninstall_command (app, command_status)), true, true, 0);
			card.pack_start (copy_row, false, false, 0);
			card.pack_start (command_status, false, false, 0);
			card.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 2);

			var desktop = app as DesktopAppInfo;
			if (desktop != null) {
				foreach (unowned string action in desktop.list_actions ()) {
					var action_name = desktop.get_action_name (action);
					if (action_name == null || action_name == "")
						continue;
					var action_id = action;
					card.pack_start (context_action_button (action_name, "list-add-symbolic", () => {
						desktop.launch_action (action_id, null);
						context.hide ();
						hide_animated ();
					}), false, false, 0);
				}
			}

			context_menu_open = true;
			context.hide.connect (() => {
				if (uninstall_detection == detection)
					detection.cancel ();
				context_menu_open = false;
				if (visible && !context_dialog_open)
					Idle.add (() => { present (); return false; });
			});
			context.focus_out_event.connect (() => {
				if (!context_dialog_open)
					context.hide ();
				return false;
			});
			context.key_press_event.connect ((key) => {
				if (key.keyval == Gdk.Key.Escape) {
					context.hide ();
					return true;
				}
				return false;
			});
			// Grows out of the place which was clicked, like the launcher does out of its button
			var context_transition = new WindowTransition (context);
			context.set_data<WindowTransition> ("launcher-context-transition", context_transition);
			unowned WindowTransition appearing = context_transition;
			context.draw.connect ((cr) => {
				if (appearing.progress != 1.0 && Motion.movement_enabled (controller.prefs)) {
					int context_x, context_y;
					context.get_position (out context_x, out context_y);
					var origin_x = (root_x - context_x).clamp (0.0, context.get_allocated_width ());
					var origin_y = (root_y - context_y).clamp (0.0, context.get_allocated_height ());
					var scale = Motion.POPUP_SCALE + (1.0 - Motion.POPUP_SCALE) * appearing.progress;
					cr.translate (origin_x, origin_y);
					cr.scale (scale, scale);
					cr.translate (-origin_x, -origin_y);
				}
				// A window which paints itself gets no background from GTK
				unowned Gtk.StyleContext style = context.get_style_context ();
				var width = context.get_allocated_width ();
				var height = context.get_allocated_height ();
				style.render_background (cr, 0, 0, width, height);
				style.render_frame (cr, 0, 0, width, height);
				return false;
			});
			context_transition.jump_to (0.0);
			context.show_all ();
			context.present ();
			Idle.add (() => {
				position_application_context (context, root_x, root_y);
				appearing.animate_to (1.0,
					Motion.duration (controller.prefs, Motion.POPUP_OPEN_TIME), false, true);
				return false;
			});

			var desktop_filename = (app as DesktopAppInfo)?.get_filename ();
			uninstall_service.detect.begin (app.get_id () ?? "", app.get_executable () ?? "",
				desktop_filename, detection, (obj, result) => {
					var target = uninstall_service.detect.end (result);
					if (detection.is_cancelled () || application_context != context)
						return;
					origin.label = target != null
						? _("Installed via %s").printf (target.source) : _("Installed application");
					if (target != null) {
						card.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 2);
						var uninstall = context_action_button (_("Uninstall…"), "user-trash-symbolic", () => {
							context_dialog_open = true;
							context.hide ();
							confirm_uninstall (app, target);
						});
						uninstall.get_style_context ().add_class ("destructive-action");
						card.pack_start (uninstall, false, false, 0);
					}
					card.show_all ();
					position_application_context (context, root_x, root_y);
				});
		}

		void position_application_context (Gtk.Window context, double root_x, double root_y)
		{
			int width, height;
			context.get_size (out width, out height);
			var screen = context.get_screen ();
			var monitor = screen.get_monitor_at_point ((int) root_x, (int) root_y);
			var workarea = screen.get_monitor_workarea (monitor);
			var x = int.max (workarea.x + 8, int.min (workarea.x + workarea.width - width - 8, (int) root_x));
			var y = int.max (workarea.y + 8, int.min (workarea.y + workarea.height - height - 8, (int) root_y));
			context.move (x, y);
		}

		delegate void ContextAction ();

		Gtk.Button context_chip_button (string label, string description, owned ContextAction action)
		{
			var button = new Gtk.Button.with_label (label);
			button.get_style_context ().add_class ("app-context-chip");
			button.tooltip_text = description;
			Accessibility.describe (button, description);
			button.clicked.connect (() => { action (); });
			return button;
		}

		Gtk.Button context_action_button (string label, string icon, owned ContextAction action)
		{
			var button = new Gtk.Button ();
			button.get_style_context ().add_class ("app-context-action");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
			box.pack_start (new Gtk.Image.from_icon_name (icon, Gtk.IconSize.MENU), false, false, 0);
			box.pack_start (new Gtk.Label (label) { xalign = 0.0f }, true, true, 0);
			button.add (box);
			button.clicked.connect (() => { action (); });
			return button;
		}

		void confirm_uninstall (AppInfo app, UninstallTarget target)
		{
			context_menu_open = true;
			var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL,
				Gtk.MessageType.WARNING, Gtk.ButtonsType.CANCEL,
				_("Uninstall %s?").printf (app.get_display_name ()));
			dialog.format_secondary_text (_("This will remove %s using %s. Your personal data may be kept by the package manager.")
				.printf (target.package_id, target.source));
			dialog.add_button (_("Uninstall"), Gtk.ResponseType.ACCEPT);
			dialog.set_default_response (Gtk.ResponseType.CANCEL);
			dialog.response.connect ((response) => {
				dialog.destroy ();
				context_dialog_open = false;
				context_menu_open = false;
				if (response == Gtk.ResponseType.ACCEPT)
					run_uninstall (target);
				else if (visible)
					present ();
			});
			dialog.show_all ();
		}

		void run_uninstall (UninstallTarget target)
		{
			try {
				Pid pid;
				Process.spawn_async (null, target.argv, null,
					SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
				ChildWatch.add (pid, (child_pid, status) => {
					Process.close_pid (child_pid);
					try {
						Process.check_wait_status (status);
						notice_model.dismiss ();
						index_applications ();
						if (visible)
							refresh_results ();
					} catch (Error e) {
						warning ("Unable to uninstall '%s': %s", target.package_id, e.message);
						show_launcher_error (_("The package manager could not complete the uninstall. Check its status and try again."));
					}
				});
			} catch (Error e) {
				warning ("Unable to uninstall '%s': %s", target.package_id, e.message);
				show_launcher_error (_("The application could not be uninstalled. Please try again."));
			}
		}

		Gtk.Widget create_alphabet_header (string initial)
		{
			var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 9);
			header.get_style_context ().add_class ("launcher-alpha-header");
			var label = new Gtk.Label (initial) { valign = Gtk.Align.CENTER };
			label.get_style_context ().add_class ("launcher-alpha-letter");
			header.pack_start (label, false, false, 0);
			header.show_all ();
			return header;
		}

		bool handle_key_press (Gdk.EventKey event)
		{
			Accessibility.set_keyboard_navigation (this, true);
			switch (event.keyval) {
			case Gdk.Key.Tab:
			case Gdk.Key.ISO_Left_Tab:
				advance_keyboard_focus ((event.state & Gdk.ModifierType.SHIFT_MASK) != 0);
				return true;
			case Gdk.Key.Escape:
				if (search_entry.text != "")
					search_entry.text = "";
				else
					hide_animated ();
				return true;
			case Gdk.Key.Up:
				move_selection (-1);
				return true;
			case Gdk.Key.Down:
				move_selection (1);
				return true;
			case Gdk.Key.Home:
				move_selection_to (0);
				return true;
			case Gdk.Key.End:
				move_selection_to (get_result_count () - 1);
				return true;
			case Gdk.Key.Page_Up:
				move_selection (-get_page_size ());
				return true;
			case Gdk.Key.Page_Down:
				move_selection (get_page_size ());
				return true;
			case Gdk.Key.F10:
				if ((event.state & Gdk.ModifierType.SHIFT_MASK) != 0) {
					show_selected_application_context ();
					return true;
				}
				return false;
			case Gdk.Key.Menu:
				show_selected_application_context ();
				return true;
			case Gdk.Key.Return:
			case Gdk.Key.KP_Enter:
				var row = result_list.get_selected_row ();
				if (row != null && (get_focus () == search_entry || get_focus () == row))
					activate_row (row);
				else
					return false;
				return true;
			default:
				return false;
			}
		}

		void advance_keyboard_focus (bool backwards)
		{
			var targets = new Gee.ArrayList<Gtk.Widget> ();
			targets.add (user_avatar_button);
			targets.add (search_entry);
			var row = result_list.get_selected_row ();
			if (row != null && row.selectable)
				targets.add (row);
			if (notice_revealer.reveal_child)
				targets.add (dismiss_notice_button);

			if (targets.size == 0)
				return;
			var focus = get_focus ();
			var current_index = targets.index_of (focus);
			var next_index = current_index < 0
				? (backwards ? targets.size - 1 : 0)
				: (current_index + (backwards ? targets.size - 1 : 1)) % targets.size;
			var target = targets[next_index];
			if (target is Gtk.ListBoxRow)
				result_list.select_row ((Gtk.ListBoxRow) target);
			target.grab_focus ();
		}

		void move_selection (int delta)
		{
			var result_count = get_result_count ();
			if (result_count == 0)
				return;
			var row = result_list.get_selected_row ();
			var index = row == null ? 0 : row.get_index () + delta;
			if (delta == -1 || delta == 1)
				index = (index + result_count) % result_count;
			else
				index = int.max (0, int.min (result_count - 1, index));
			move_selection_to (index);
		}

		void move_selection_to (int index)
		{
			var result_count = get_result_count ();
			if (result_count == 0)
				return;
			index = int.max (0, int.min (result_count - 1, index));
			var row = result_list.get_row_at_index (index);
			if (row != null && row.selectable) {
				var focus_is_result = get_focus () is Gtk.ListBoxRow;
				result_list.select_row (row);
				if (focus_is_result)
					row.grab_focus ();
			}
		}

		int get_result_count ()
		{
			if (showing_calculation)
				return 1;
			// Applications come first, then commands, then the remaining actions
			return visible_results.size + visible_commands.size + visible_actions.size;
		}

		int get_page_size ()
		{
			var row = result_list.get_selected_row ();
			var row_height = row == null ? 0 : row.get_allocated_height ();
			if (row_height <= 0)
				row_height = 48;
			return int.max (1, result_list.get_allocated_height () / row_height);
		}

		void show_selected_application_context ()
		{
			if (showing_commands || showing_calculation)
				return;
			var row = result_list.get_selected_row ();
			if (row == null || row.get_index () < 0 || row.get_index () >= visible_results.size)
				return;
			int row_x, row_y;
			if (!row.translate_coordinates (this, 0, 0, out row_x, out row_y))
				return;
			int window_x, window_y;
			get_window ().get_origin (out window_x, out window_y);
			show_application_context_menu (visible_results[row.get_index ()],
				window_x + row_x + row.get_allocated_width () / 2,
				window_y + row_y + row.get_allocated_height () / 2);
		}

		void activate_row (Gtk.ListBoxRow row)
		{
			var index = row.get_index ();
			if (showing_calculation) {
				if (index != 0)
					return;
				Gtk.Clipboard.get (Gdk.SELECTION_CLIPBOARD).set_text (calculation_result, -1);
				if (calculation_status_label != null)
					calculation_status_label.label = _("Copied");
				return;
			}
			if (index < 0)
				return;
			if (index >= visible_results.size) {
				// Applications come first, then commands, then the remaining actions
				index -= visible_results.size;
				if (index < visible_commands.size) {
					var action = visible_commands[index];
					var command = listed_commands[action];
					if (command != null) {
						run_command (command);
					} else if (action == "preferences") {
						Application.get_default ().activate_action ("preferences", null);
						hide_animated ();
					} else {
						run_session_action (action);
					}
				} else if (index - visible_commands.size < visible_actions.size) {
					run_action (visible_actions[index - visible_commands.size]);
				}
				return;
			}
			try {
				var app = visible_results[index];
				app.launch (null, null);
				usage.record (LauncherCatalog.usage_id (app));
				// The most used applications may have changed their order
				catalog_ready = false;
				notice_model.dismiss ();
				hide_animated ();
			} catch (Error e) {
				warning ("Unable to launch '%s': %s", visible_results[index].get_name (), e.message);
				show_launcher_error (_("The application could not be opened. Check that it is still installed and try again."));
			}
		}

		void position_centered ()
		{
			if (anchor_item == null)
				return;
			int width, height;
			get_size (out width, out height);
			var bar_rect = controller.position_manager.get_screen_background_region ();
			var screen = get_screen ();
			var monitor = screen.get_monitor_at_point (
				bar_rect.x + bar_rect.width / 2, bar_rect.y + bar_rect.height / 2);
			var workarea = screen.get_monitor_workarea (monitor);
			PositionManager.calculate_centered_popup_position (workarea, width, height,
				out panel_x, out panel_y);
			move (panel_x, panel_y);

			growth_x = width / 2.0;
			growth_y = height / 2.0;
			int dock_x, dock_y;
			controller.window.get_position (out dock_x, out dock_y);
			var button = controller.position_manager.get_draw_value_for_item (anchor_item).center;
			if (width > 2 * PANEL_MARGIN && height > 2 * PANEL_MARGIN) {
				growth_x = (dock_x + button.x - panel_x).clamp (PANEL_MARGIN, width - PANEL_MARGIN);
				growth_y = (dock_y + button.y - panel_y).clamp (PANEL_MARGIN, height - PANEL_MARGIN);
			}
		}

		void apply_theme ()
		{
			DockStyle.update (controller);
			// The highlight of the selected row is painted, not styled
			if (ContextMenuStyle.is_light (controller.renderer.theme.FillStartColor))
				selection_glide.color = { 24 / 255.0, 27 / 255.0, 32 / 255.0, 0.16 };
			else
				selection_glide.color = { 1.0, 1.0, 1.0, 0.16 };
			selection_glide.animate = Motion.movement_enabled (controller.prefs);
		}

		void hide_animated ()
		{
			if (!visible)
				return;
			transition.animate_to (0.0,
				Motion.duration (controller.prefs, CLOSE_ANIMATION_TIME), true);
		}

		public override bool draw (Cairo.Context cr)
		{
			// The window itself stays put. Its content grows out of the launcher
			// button while appearing and shrinks back into it while leaving.
			if (transition.progress != 1.0 && Motion.movement_enabled (controller.prefs)) {
				var scale = Motion.POPUP_SCALE + (1.0 - Motion.POPUP_SCALE) * transition.progress;
				cr.translate (growth_x, growth_y);
				cr.scale (scale, scale);
				cr.translate (-growth_x, -growth_y);
			}
			return base.draw (cr);
		}

		void start_cascade ()
		{
			stop_cascade ();
			if (!Motion.movement_enabled (controller.prefs))
				return;

			var speed = Motion.duration_scale (controller.prefs);
			var stagger = CASCADE_STAGGER * 1000.0 * speed;
			var fade_time = CASCADE_FADE_TIME * 1000.0 * speed;
			set_cascade_progress (0.0, stagger, fade_time);
			cascade_start = 0LL;
			cascade_tick_id = add_tick_callback ((widget, frame_clock) => {
				var now = frame_clock.get_frame_time ();
				if (cascade_start == 0LL)
					cascade_start = now;
				if (set_cascade_progress (now - cascade_start, stagger, fade_time))
					return Source.CONTINUE;
				cascade_tick_id = 0U;
				return Source.REMOVE;
			});
		}

		/**
		 * Shows the first rows as far as they got after the given time.
		 *
		 * @return whether some of them are still appearing
		 */
		bool set_cascade_progress (double elapsed, double stagger, double fade_time)
		{
			var appearing = false;
			for (var i = 0; i < CASCADE_ROWS; i++) {
				var row = result_list.get_row_at_index (i);
				if (row == null)
					break;
				var progress = ((elapsed - i * stagger) / fade_time).clamp (0.0, 1.0);
				if (progress < 1.0)
					appearing = true;
				set_row_opacity (row, easing_for_mode (AnimationMode.EASE_OUT_CUBIC, progress, 1.0));
			}
			return appearing;
		}

		void stop_cascade ()
		{
			if (cascade_tick_id > 0U) {
				remove_tick_callback (cascade_tick_id);
				cascade_tick_id = 0U;
			}
			// Rows are kept and reused, none may stay half faded
			foreach (unowned Gtk.Widget child in result_list.get_children ())
				set_row_opacity ((Gtk.ListBoxRow) child, 1.0);
			foreach (var row in application_rows.values)
				set_row_opacity (row, 1.0);
			foreach (var row in frequent_rows.values)
				set_row_opacity (row, 1.0);
		}

		static void set_row_opacity (Gtk.ListBoxRow row, double opacity)
		{
			row.opacity = opacity;
			unowned Gtk.Widget? header = row.get_header ();
			if (header != null)
				header.opacity = opacity;
		}
	}
}
