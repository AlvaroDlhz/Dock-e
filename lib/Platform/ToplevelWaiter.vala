//
//  Copyright (C) 2026 Dock-E
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Plank is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Plank.Platform
{
	public delegate void ToplevelReady (Toplevel toplevel);

	/**
	 * Runs actions on a toplevel as soon as the toplevel manager knows it.
	 * Another source may announce a window first, as an application matcher
	 * running in another process can.
	 */
	public class ToplevelWaiter : Object
	{
		class Pending
		{
			public ToplevelReady action;

			public Pending (owned ToplevelReady action)
			{
				this.action = (owned) action;
			}
		}

		ToplevelManager toplevels;
		// Keyed by the id as text, which Gee hashes without boxing
		Gee.HashMap<string, Gee.ArrayList<Pending>> waiting;

		public ToplevelWaiter (ToplevelManager toplevels)
		{
			this.toplevels = toplevels;
			waiting = new Gee.HashMap<string, Gee.ArrayList<Pending>> ();
			toplevels.added.connect (handle_added);
		}

		~ToplevelWaiter ()
		{
			toplevels.added.disconnect (handle_added);
		}

		/**
		 * Runs action now if the toplevel is known, or once it is added.
		 */
		public void run (uint64 id, owned ToplevelReady action)
		{
			var toplevel = toplevels.lookup_id (id);
			if (toplevel != null) {
				action (toplevel);
				return;
			}

			var list = waiting.get (id.to_string ());
			if (list == null) {
				list = new Gee.ArrayList<Pending> ();
				waiting.set (id.to_string (), list);
			}
			list.add (new Pending ((owned) action));
		}

		/**
		 * Forgets the actions waiting for a window which went away.
		 */
		public void cancel (uint64 id)
		{
			waiting.unset (id.to_string ());
		}

		public bool is_waiting (uint64 id)
		{
			return waiting.has_key (id.to_string ());
		}

		void handle_added (Toplevel toplevel)
		{
			Gee.ArrayList<Pending> list;
			if (!waiting.unset (toplevel.id.to_string (), out list))
				return;

			foreach (var pending in list)
				pending.action (toplevel);
		}
	}
}
