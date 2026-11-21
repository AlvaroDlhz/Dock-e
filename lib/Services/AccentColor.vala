//
// The color which marks what is focused, active or checked.
//

namespace Plank
{
	/**
	 * Decides the accent color: a fixed one, or one taken from the desktop
	 * wallpaper, which is then followed as it changes.
	 *
	 * Nothing is polled. The desktop announces a new wallpaper, and the
	 * picture is read once, scaled down, off the main thread.
	 */
	public class AccentColor : Object
	{
		/**
		 * The accent used unless something else is asked for or found.
		 */
		public const string DEFAULT = "#73d216";
		/**
		 * The value of {@link source} which follows the wallpaper.
		 */
		public const string AUTOMATIC = "auto";

		const string XFCONF_NAME = "org.xfce.Xfconf";
		const string XFCONF_PATH = "/org/xfce/Xfconf";
		const string XFCONF_CHANNEL = "xfce4-desktop";
		const string XFCONF_IMAGE_KEY = "/last-image";
		const string GNOME_SCHEMA = "org.gnome.desktop.background";
		// The wallpaper is only looked at this small
		const int SAMPLE_SIZE = 48;
		const int HUES = 24;
		// A new wallpaper is announced once per monitor and workspace
		const uint REFRESH_DELAY = 300U;

		/**
		 * The accent changed.
		 */
		public signal void changed ();

		/**
		 * The accent to use right now.
		 */
		public Gdk.RGBA color { get; private set; }

		string _source = "";
		/**
		 * Where the accent comes from: {@link AUTOMATIC}, a color as CSS
		 * writes it, or nothing for {@link DEFAULT}.
		 */
		public string source {
			get { return _source; }
			set {
				if (_source == value)
					return;
				_source = value;
				apply_source ();
			}
		}

		// The names of the monitors in use, the one of the dock first.
		// Desktops keep the wallpapers of monitors which are long gone.
		string[] monitors = {};
		DBusConnection? connection;
		uint xfconf_subscription_id = 0U;
		GLib.Settings? gnome_settings;
		ulong gnome_changed_id = 0UL;
		uint refresh_timer_id = 0U;
		Cancellable? loading;
		string sampled_path = "";

		public AccentColor ()
		{
			Gdk.RGBA fallback = {};
			fallback.parse (DEFAULT);
			color = fallback;
		}

		~AccentColor ()
		{
			unwatch ();
		}

		/**
		 * Tells which monitors are in use, the preferred one first.
		 */
		public void set_monitors (string[] names)
		{
			monitors = names;
			if (_source == AUTOMATIC)
				schedule_refresh ();
		}

		void apply_source ()
		{
			if (_source == AUTOMATIC) {
				watch.begin ();
				return;
			}
			unwatch ();
			sampled_path = "";
			Gdk.RGBA fixed = {};
			if (_source == "" || !fixed.parse (_source))
				fixed.parse (DEFAULT);
			fixed.alpha = 1.0;
			adopt (fixed);
		}

		void adopt (Gdk.RGBA value)
		{
			if (color.equal (value))
				return;
			color = value;
			changed ();
		}

		async void watch ()
		{
			if (connection == null) {
				try {
					connection = yield Bus.@get (BusType.SESSION);
				} catch (Error e) {
					debug ("No session bus to ask for the wallpaper: %s", e.message);
				}
			}
			// The source may have changed while waiting
			if (_source != AUTOMATIC)
				return;
			if (connection != null && xfconf_subscription_id == 0U)
				xfconf_subscription_id = subscribe (connection, this);
			if (gnome_settings == null) {
				unowned SettingsSchemaSource? schemas = SettingsSchemaSource.get_default ();
				if (schemas != null && schemas.lookup (GNOME_SCHEMA, true) != null) {
					gnome_settings = new GLib.Settings (GNOME_SCHEMA);
					gnome_changed_id = connect_settings (gnome_settings, this);
				}
			}
			refresh.begin ();
		}

		// Neither subscription may keep this alive, or it would never be
		// finalized and so never give them up. Both end in unwatch ().
		static uint subscribe (DBusConnection connection, AccentColor accent)
		{
			unowned AccentColor target = accent;
			return connection.signal_subscribe (XFCONF_NAME, XFCONF_NAME, "PropertyChanged",
				XFCONF_PATH, XFCONF_CHANNEL, DBusSignalFlags.NONE,
				(conn, sender, path, iface, name, parameters) => {
					var property = parameters.get_child_value (1).get_string ();
					if (property.has_suffix (XFCONF_IMAGE_KEY))
						target.schedule_refresh ();
				});
		}

		static ulong connect_settings (GLib.Settings settings, AccentColor accent)
		{
			unowned AccentColor target = accent;
			return settings.changed.connect ((key) => {
				if (key.has_prefix ("picture-uri"))
					target.schedule_refresh ();
			});
		}

		void unwatch ()
		{
			if (refresh_timer_id > 0U) {
				Source.remove (refresh_timer_id);
				refresh_timer_id = 0U;
			}
			if (loading != null) {
				loading.cancel ();
				loading = null;
			}
			if (connection != null && xfconf_subscription_id > 0U) {
				connection.signal_unsubscribe (xfconf_subscription_id);
				xfconf_subscription_id = 0U;
			}
			if (gnome_settings != null && gnome_changed_id > 0UL) {
				SignalHandler.disconnect (gnome_settings, gnome_changed_id);
				gnome_changed_id = 0UL;
			}
			gnome_settings = null;
		}

		void schedule_refresh ()
		{
			if (refresh_timer_id > 0U)
				Source.remove (refresh_timer_id);
			refresh_timer_id = Timeout.add (REFRESH_DELAY, () => {
				refresh_timer_id = 0U;
				refresh.begin ();
				return false;
			});
		}

		async void refresh ()
		{
			if (loading != null)
				loading.cancel ();
			var cancellable = new Cancellable ();
			loading = cancellable;

			var path = yield find_wallpaper (cancellable);
			if (cancellable.is_cancelled () || _source != AUTOMATIC)
				return;
			if (path == null) {
				debug ("No wallpaper found, the accent stays as it is");
				return;
			}
			if (path == sampled_path)
				return;

			Gdk.Pixbuf pixbuf;
			try {
				var stream = yield File.new_for_path (path).read_async (Priority.LOW, cancellable);
				pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async (stream,
					SAMPLE_SIZE, SAMPLE_SIZE, true, cancellable);
			} catch (Error e) {
				if (!(e is IOError.CANCELLED))
					debug ("Unable to read the wallpaper '%s': %s", path, e.message);
				return;
			}
			if (cancellable.is_cancelled () || _source != AUTOMATIC)
				return;
			sampled_path = path;

			Gdk.RGBA picked;
			if (!pick (pixbuf, out picked))
				picked.parse (DEFAULT);
			debug ("Accent %s from the wallpaper '%s'", picked.to_string (), path);
			adopt (picked);
		}

		async string? find_wallpaper (Cancellable cancellable)
		{
			if (connection != null) {
				try {
					// A desktop which is not XFCE must not be made to start its settings daemon
					var reply = yield connection.call (XFCONF_NAME, XFCONF_PATH, XFCONF_NAME,
						"GetAllProperties", new Variant ("(ss)", XFCONF_CHANNEL, "/backdrop"),
						new VariantType ("(a{sv})"), DBusCallFlags.NO_AUTO_START, 2000, cancellable);
					var images = new Gee.HashMap<string, string> ();
					VariantIter properties = reply.get_child_value (0).iterator ();
					string key;
					Variant value;
					while (properties.next ("{sv}", out key, out value)) {
						if (key.has_suffix (XFCONF_IMAGE_KEY) && value.is_of_type (VariantType.STRING))
							images[key] = value.get_string ();
					}
					var path = choose_xfce_wallpaper (images, monitors);
					if (path != null)
						return path;
				} catch (Error e) {
					debug ("XFCE does not tell its wallpaper: %s", e.message);
				}
			}
			if (gnome_settings != null) {
				var uri = gnome_settings.get_string ("picture-uri");
				if (uri != "") {
					var path = File.new_for_uri (uri).get_path ();
					if (path != null && FileUtils.test (path, FileTest.IS_REGULAR))
						return path;
				}
			}
			return null;
		}

		/**
		 * Which of the wallpapers XFCE knows is the one in view.
		 *
		 * @param images the pictures by their property, which names a monitor and a workspace
		 * @param monitors the names of the monitors in use, the preferred one first
		 */
		public static string? choose_xfce_wallpaper (Gee.Map<string, string> images, string[] monitors)
		{
			var keys = new Gee.ArrayList<string> ();
			keys.add_all (images.keys);
			keys.sort ((a, b) => strcmp (a, b));

			// A monitor in use before any other, its first workspace before the rest
			foreach (var monitor in monitors) {
				var marker = "/monitor%s/".printf (monitor);
				foreach (var first_workspace in new bool[] { true, false }) {
					foreach (var key in keys) {
						if (!key.contains (marker) || key.contains ("/workspace0/") != first_workspace)
							continue;
						if (FileUtils.test (images[key], FileTest.IS_REGULAR))
							return images[key];
					}
				}
			}
			foreach (var key in keys)
				if (FileUtils.test (images[key], FileTest.IS_REGULAR))
					return images[key];
			return null;
		}

		/**
		 * Picks the color which stands out in a picture: the hue most of its
		 * colorful pixels share, at a strength which reads well as an accent.
		 *
		 * @return false for a picture without any color to speak of
		 */
		public static bool pick (Gdk.Pixbuf pixbuf, out Gdk.RGBA accent)
		{
			accent = {};
			accent.alpha = 1.0;

			var weights = new double[HUES];
			var hue_sums = new double[HUES];
			var saturation_sums = new double[HUES];
			var total = 0.0;

			unowned uint8[] pixels = pixbuf.get_pixels ();
			var channels = pixbuf.n_channels;
			var rowstride = pixbuf.rowstride;
			for (var y = 0; y < pixbuf.height; y++) {
				for (var x = 0; x < pixbuf.width; x++) {
					var offset = y * rowstride + x * channels;
					if (channels == 4 && pixels[offset + 3] < 128)
						continue;
					double hue, saturation, brightness;
					to_hsv (pixels[offset] / 255.0, pixels[offset + 1] / 255.0,
						pixels[offset + 2] / 255.0, out hue, out saturation, out brightness);
					// Greys and near blacks have a hue only by accident
					if (saturation < 0.18 || brightness < 0.18)
						continue;
					var weight = saturation * saturation * brightness;
					var bin = ((int) (hue * HUES)).clamp (0, HUES - 1);
					weights[bin] += weight;
					hue_sums[bin] += hue * weight;
					saturation_sums[bin] += saturation * weight;
					total += weight;
				}
			}

			// A few stray colorful pixels do not make a picture colorful
			if (total < pixbuf.width * pixbuf.height * 0.004)
				return false;

			var best = 0;
			for (var i = 1; i < HUES; i++)
				if (weights[i] > weights[best])
					best = i;
			var best_hue = hue_sums[best] / weights[best];
			var best_saturation = (saturation_sums[best] / weights[best]).clamp (0.55, 0.85);
			double red, green, blue;
			from_hsv (best_hue, best_saturation, 0.86, out red, out green, out blue);
			accent.red = red;
			accent.green = green;
			accent.blue = blue;
			return true;
		}

		static void to_hsv (double red, double green, double blue,
			out double hue, out double saturation, out double brightness)
		{
			var max = double.max (red, double.max (green, blue));
			var min = double.min (red, double.min (green, blue));
			var delta = max - min;
			brightness = max;
			saturation = max <= 0.0 ? 0.0 : delta / max;
			hue = 0.0;
			if (delta <= 0.0)
				return;
			if (max == red)
				hue = (green - blue) / delta + (green < blue ? 6.0 : 0.0);
			else if (max == green)
				hue = (blue - red) / delta + 2.0;
			else
				hue = (red - green) / delta + 4.0;
			hue /= 6.0;
		}

		static void from_hsv (double hue, double saturation, double brightness,
			out double red, out double green, out double blue)
		{
			var scaled = hue * 6.0;
			var sector = ((int) Math.floor (scaled)) % 6;
			var fraction = scaled - Math.floor (scaled);
			var p = brightness * (1.0 - saturation);
			var q = brightness * (1.0 - saturation * fraction);
			var t = brightness * (1.0 - saturation * (1.0 - fraction));
			switch (sector) {
			default:
			case 0: red = brightness; green = t; blue = p; break;
			case 1: red = q; green = brightness; blue = p; break;
			case 2: red = p; green = brightness; blue = t; break;
			case 3: red = p; green = q; blue = brightness; break;
			case 4: red = t; green = p; blue = brightness; break;
			case 5: red = brightness; green = p; blue = q; break;
			}
		}
	}
}
