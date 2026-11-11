//
// Text matching and usage history for the launcher.
//

namespace Plank
{
	/**
	 * Matches what is typed into the launcher against names.
	 */
	public class LauncherSearch : Object
	{
		/**
		 * Lowers the case and drops the accents of a text, so that
		 * "configuracion" finds "Configuración". Every character stays
		 * exactly one character, which keeps positions comparable.
		 */
		public static string normalize (string text)
		{
			var builder = new StringBuilder.sized (text.length);
			unichar c;
			for (var i = 0; text.get_next_char (ref i, out c);) {
				c = c.tolower ();
				if (c > 127) {
					var decomposed = c.to_string ().normalize (-1, NormalizeMode.NFD);
					if (decomposed != null && decomposed.get_char () != 0)
						c = decomposed.get_char ();
				}
				builder.append_unichar (c);
			}
			return builder.str;
		}

		/**
		 * The first letters of the words of a normalized text, e.g. "vsc"
		 * for "visual studio code".
		 */
		public static string initials (string normalized)
		{
			var builder = new StringBuilder ();
			var at_word_start = true;
			unichar c;
			for (var i = 0; normalized.get_next_char (ref i, out c);) {
				if (!c.isalnum ()) {
					at_word_start = true;
					continue;
				}
				if (at_word_start)
					builder.append_unichar (c);
				at_word_start = false;
			}
			return builder.str;
		}

		/**
		 * Rates how well a text matches what was typed. Both have to be normalized.
		 *
		 * @return a higher number for a better match, negative for none at all
		 */
		public static int score (string text, string query)
		{
			if (query == "")
				return 0;
			if (text.has_prefix (query))
				return 1000 - int.min (99, text.length);

			var word = word_start_index (text, query);
			if (word >= 0)
				return 900 - int.min (49, word);

			if (query.char_count () >= 2 && initials (text).has_prefix (query))
				return 850;

			var exact = text.index_of (query);
			if (exact >= 0)
				return 800 - int.min (99, exact);

			var query_index = 0;
			var first_match = -1;
			var previous_match = -2;
			var consecutive = 0;
			for (var i = 0; i < text.length && query_index < query.length; i++) {
				if (text[i] != query[query_index])
					continue;
				if (first_match < 0)
					first_match = i;
				if (i == previous_match + 1)
					consecutive++;
				previous_match = i;
				query_index++;
			}
			if (query_index < query.length)
				return -1;
			return int.max (0, 400 + consecutive * 10 - first_match - (previous_match - first_match));
		}

		/**
		 * Whether a text matches clearly: at its start, at the start of
		 * one of its words or by its initials. Loose matches do not count.
		 */
		public static bool matches_clearly (string text, string query)
		{
			return query != "" && score (text, query) >= 850;
		}

		/**
		 * Marks the letters of a name which what was typed matched.
		 *
		 * @param name the name as it is shown
		 * @param query the normalized text which was typed
		 * @return Pango markup for the name
		 */
		public static string highlight (string name, string query)
		{
			var normalized = normalize (name);
			var length = name.char_count ();
			var marked = new bool[length];
			var any = false;

			if (query != "" && normalized.char_count () == length) {
				var start = -1;
				if (normalized.has_prefix (query))
					start = 0;
				else
					start = word_start_index (normalized, query);

				if (start < 0 && query.char_count () >= 2 && initials (normalized).has_prefix (query)) {
					// One letter per word, for as many words as were typed
					var remaining = query.char_count ();
					var at_word_start = true;
					var position = 0;
					unichar c = 0;
					for (var i = 0; remaining > 0 && normalized.get_next_char (ref i, out c); position++) {
						if (!c.isalnum ()) {
							at_word_start = true;
							continue;
						}
						if (at_word_start) {
							marked[position] = true;
							any = true;
							remaining--;
						}
						at_word_start = false;
					}
				} else {
					if (start < 0)
						start = normalized.index_of (query);
					if (start >= 0) {
						var first = normalized.substring (0, start).char_count ();
						for (var i = 0; i < query.char_count () && first + i < length; i++)
							marked[first + i] = true;
						any = true;
					} else {
						// The typed letters in order, wherever they are
						var position = 0;
						var query_offset = 0;
						unichar wanted;
						var has_wanted = query.get_next_char (ref query_offset, out wanted);
						unichar c = 0;
						for (var i = 0; has_wanted && normalized.get_next_char (ref i, out c); position++) {
							if (c != wanted)
								continue;
							marked[position] = true;
							has_wanted = query.get_next_char (ref query_offset, out wanted);
						}
						// Only a complete match is worth showing
						any = !has_wanted;
					}
				}
			}

			if (!any)
				return Markup.escape_text (name);

			var builder = new StringBuilder ();
			var position = 0;
			var open = false;
			unichar c;
			for (var i = 0; name.get_next_char (ref i, out c); position++) {
				var mark = position < length && marked[position];
				if (mark != open || position == 0) {
					if (position > 0)
						builder.append ("</span>");
					builder.append (mark ? "<span weight=\"800\">" : "<span alpha=\"62%\">");
					open = mark;
				}
				builder.append (Markup.escape_text (c.to_string ()));
			}
			if (position > 0)
				builder.append ("</span>");
			return builder.str;
		}

		/**
		 * The byte position of the first word starting with what was typed.
		 */
		static int word_start_index (string text, string query)
		{
			var from = 0;
			while (true) {
				var found = text.index_of (query, from);
				if (found < 0)
					return -1;
				if (found == 0)
					return 0;
				var prefix = text.substring (0, found);
				var before = prefix.get_char (prefix.index_of_nth_char (prefix.char_count () - 1));
				if (!before.isalnum ())
					return found;
				from = found + 1;
			}
		}
	}

	/**
	 * Remembers which applications get opened from the launcher, so the
	 * ones used most and most recently can be offered first.
	 */
	public class LauncherUsage : Object
	{
		// A launch counts half as much after this many days
		const double HALF_LIFE_DAYS = 30.0;
		const string COUNT_KEY = "Count";
		const string LAST_KEY = "Last";

		public File? file { get; construct; }

		KeyFile store;

		/**
		 * @param file where to keep the history, or null to keep it in memory only
		 */
		public LauncherUsage (File? file)
		{
			Object (file : file);
		}

		construct
		{
			store = new KeyFile ();
			if (file == null)
				return;
			try {
				store.load_from_file (file.get_path (), KeyFileFlags.NONE);
			} catch (Error e) {
				// There simply is no history yet
				store = new KeyFile ();
			}
		}

		/**
		 * Notes that an application was just opened.
		 *
		 * @param id the id of the application
		 * @param now the current time in seconds, or 0 for the real time
		 */
		public void record (string id, int64 now = 0)
		{
			if (id == "")
				return;
			if (now == 0)
				now = get_real_time () / 1000000;
			store.set_double (id, COUNT_KEY, score (id, now) + 1.0);
			store.set_int64 (id, LAST_KEY, now);
			save ();
		}

		/**
		 * How much an application is used: its launches, each counting less the older it is.
		 *
		 * @param id the id of the application
		 * @param now the current time in seconds, or 0 for the real time
		 */
		public double score (string id, int64 now = 0)
		{
			if (id == "" || !store.has_group (id))
				return 0.0;
			if (now == 0)
				now = get_real_time () / 1000000;
			try {
				var count = store.get_double (id, COUNT_KEY);
				var last = store.get_int64 (id, LAST_KEY);
				var days = double.max (0.0, (now - last) / 86400.0);
				return count * Math.pow (0.5, days / HALF_LIFE_DAYS);
			} catch (Error e) {
				return 0.0;
			}
		}

		void save ()
		{
			if (file == null)
				return;
			try {
				var folder = file.get_parent ();
				if (folder != null && !folder.query_exists ())
					folder.make_directory_with_parents ();
				store.save_to_file (file.get_path ());
			} catch (Error e) {
				warning ("Unable to save the launcher history: %s", e.message);
			}
		}
	}
}
