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

namespace Plank
{
	/**
	 * Whether the windowing system can hide all windows to show the desktop.
	 */
	public bool can_show_desktop ()
	{
		unowned Platform.Backend? backend = Platform.get_backend ();
		return (backend != null && backend.has (Platform.Capability.SHOW_DESKTOP) && backend.workspaces != null);
	}
	
	/**
	 * Hides all windows to show the desktop, or brings them back.  Does
	 * nothing if {@link can_show_desktop} is false.
	 */
	public void toggle_showing_desktop ()
	{
		if (!can_show_desktop ())
			return;
		
		unowned Platform.WorkspaceManager workspaces = Platform.get_backend ().workspaces;
		workspaces.set_showing_desktop (!workspaces.showing_desktop);
	}
}
