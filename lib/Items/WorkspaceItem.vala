// Workspace overview entry point.

namespace Plank
{
	public class WorkspaceItem : DockItem
	{
		Gdk.Pixbuf? areas_pixbuf = null;

		public WorkspaceItem ()
		{
			Object (Prefs: new DockItemPreferences (), Text: _("Workspaces"),
				Icon: "preferences-desktop-workspaces-symbolic");
		}

		public override bool can_be_removed ()
		{
			return false;
		}

		protected override void draw_icon (Surface surface)
		{
			if (areas_pixbuf == null) {
				try {
					areas_pixbuf = new Gdk.Pixbuf.from_resource (G_RESOURCE_PATH + "/img/areas.svg");
				} catch (Error e) {
					warning ("Unable to load workspace image: %s", e.message);
					return;
				}
			}

			var size = (int) (int.min (surface.Width, surface.Height) * 0.72);
			var scaled = areas_pixbuf.scale_simple (size, size, Gdk.InterpType.BILINEAR);
			var x = (surface.Width - size) / 2.0;
			var y = (surface.Height - size) / 2.0;
			Gdk.cairo_set_source_pixbuf (surface.Context, scaled, x, y);
			surface.Context.paint ();
		}

		protected override AnimationType on_clicked (PopupButton button,
			Gdk.ModifierType mod, uint32 event_time)
		{
			if (button == PopupButton.LEFT) {
				unowned DockController? dock = get_dock ();
				if (dock != null)
					dock.workspace_previews.toggle (this);
				return AnimationType.DARKEN;
			}
			return AnimationType.NONE;
		}
	}
}
