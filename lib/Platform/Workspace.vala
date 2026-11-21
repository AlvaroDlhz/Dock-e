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
	/**
	 * A virtual desktop.
	 */
	public abstract class Workspace : Object
	{
		public abstract int index { get; }
		public abstract string name { get; }
		public abstract bool is_active { get; }
		/** A large desktop split in viewports (Compiz); X11 only */
		public abstract bool is_viewport { get; }

		public abstract void activate (uint32 timestamp);
	}

	public interface WorkspaceManager : Object
	{
		/**
		 * The workspaces in their order; up to date with the display server.
		 */
		public abstract Gee.List<Workspace> list ();
		public abstract Workspace? active { owned get; }

		/** Workspaces were added, removed or renamed */
		public signal void changed ();
		/**
		 * Another workspace became active, or another viewport of the
		 * active one; previous is the active workspace itself then.
		 */
		public signal void active_changed (Workspace? previous);

		public abstract bool showing_desktop { get; }
		public abstract void set_showing_desktop (bool show);
	}
}
