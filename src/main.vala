/* main.vala
 *
 * Copyright 2026 Edmar
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
using Gtk;
using Adw;
using GtkSource;
#if HAVE_VTE
using Vte;
#endif
using Graphene;

private delegate void ProfileSyncAction ();

/* =========================================================================
 * 1. Data Models & Language Templates
 * ========================================================================= */

private class LineLabelEntry : GLib.Object {
    public int line_index; // 0-based
    public string label;
    public string description;

    public LineLabelEntry (int line_index, string label, string description = "") {
        this.line_index = line_index;
        this.label = label;
        this.description = description;
    }
}

private class EditorTabData : GLib.Object {
    public GLib.File? file;
    public GtkSource.Buffer buffer;
    public GtkSource.View view;
    public bool dirty;
    public bool needs_compile;
    public int selected_line_start;
    public int selected_line_end;
    public GenericArray<LineLabelEntry> line_labels;

    public EditorTabData (GLib.File? file, GtkSource.Buffer buffer, GtkSource.View view) {
        this.file = file;
        this.buffer = buffer;
        this.view = view;
        this.dirty = false;
        this.needs_compile = false;
        this.selected_line_start = 0;
        this.selected_line_end = 0;
        this.line_labels = new GenericArray<LineLabelEntry> ();
    }

    public LineLabelEntry? find_label_for_line (int line_idx) {
        for (int i = 0; i < line_labels.length; i++) {
            if (line_labels[i].line_index == line_idx) {
                return line_labels[i];
            }
        }
        return null;
    }

    public void set_label_for_line (int line_idx, string name, string desc = "") {
        var existing = find_label_for_line (line_idx);
        if (existing != null) {
            existing.label = name;
            existing.description = desc;
            return;
        }
        line_labels.add (new LineLabelEntry (line_idx, name, desc));
    }

    public bool remove_label_for_line (int line_idx) {
        for (int i = 0; i < line_labels.length; i++) {
            if (line_labels[i].line_index == line_idx) {
                line_labels.remove_index (i);
                return true;
            }
        }
        return false;
    }
}

private class ThemeProfile : GLib.Object {
    public string name;
    public string app_theme;          // "system", "light", "dark"
    public string style_scheme;       // "auto" or GtkSourceStyleScheme id
    public string editor_font;
    public string terminal_theme;     // "vscode-blue", "vscode-dark", "adwaita-dark", "adwaita-light", "solarized-dark", "dracula", "monokai"
    public string terminal_font;
    public int tab_width;
    public bool show_line_numbers;
    public bool file_manager_enabled;
    public bool autoclose_enabled;

    public ThemeProfile (
        string name,
        string app_theme = "dark",
        string style_scheme = "auto",
        string editor_font = "Monospace 11",
        string terminal_theme = "vscode-blue",
        string terminal_font = "Monospace 10",
        int tab_width = 4,
        bool show_line_numbers = true,
        bool file_manager_enabled = true,
        bool autoclose_enabled = true
    ) {
        this.name = name;
        this.app_theme = app_theme;
        this.style_scheme = style_scheme;
        this.editor_font = editor_font;
        this.terminal_theme = terminal_theme;
        this.terminal_font = terminal_font;
        this.tab_width = tab_width.clamp (2, 8);
        this.show_line_numbers = show_line_numbers;
        this.file_manager_enabled = file_manager_enabled;
        this.autoclose_enabled = autoclose_enabled;
    }
}

private struct LanguageFormat {
    public string label;
    public string ext;
    public string default_name;
    public string base_template;
}

/* =========================================================================
 * 2. Custom SourceView (Line-Number Gutter Highlight Only)
 * ========================================================================= */

private class ErrorLineSourceView : GtkSource.View {
    private Gdk.RGBA error_gutter_bg;
    private Gdk.RGBA selected_gutter_bg;
    private bool colors_initialized = false;

    public ErrorLineSourceView.with_buffer (GtkSource.Buffer buffer) {
        Object (buffer: buffer);
        ensure_colors ();
    }

    private void ensure_colors () {
        if (colors_initialized) {
            return;
        }
        error_gutter_bg = Gdk.RGBA ();
        error_gutter_bg.parse ("#5c161c");
        selected_gutter_bg = Gdk.RGBA ();
        selected_gutter_bg.parse ("#2b5c8f");
        colors_initialized = true;
    }

    private bool line_has_tag_in_range (Gtk.TextBuffer buf, Gtk.TextTag tag, int line_num) {
        Gtk.TextIter l_start, l_end;
        buf.get_iter_at_line (out l_start, line_num);
        l_end = l_start;
        if (!l_end.ends_line ()) {
            l_end.forward_to_line_end ();
        }

        if (l_start.has_tag (tag)) {
            return true;
        }
        Gtk.TextIter probe = l_start;
        if (probe.forward_to_tag_toggle (tag)) {
            return probe.compare (l_end) < 0;
        }
        return false;
    }

    public override void snapshot_layer (Gtk.TextViewLayer layer, Gtk.Snapshot snapshot) {
        if (layer == Gtk.TextViewLayer.BELOW_TEXT) {
            ensure_colors ();
            var buf = this.get_buffer () as Gtk.TextBuffer;
            var left_gutter = this.get_gutter (Gtk.TextWindowType.LEFT);
            int gutter_w = left_gutter != null ? left_gutter.get_width () : 0;

            if (buf != null && gutter_w > 0 && this.get_show_line_numbers ()) {
                Gdk.Rectangle visible_rect;
                this.get_visible_rect (out visible_rect);

                Gtk.TextIter start_iter, end_iter;
                this.get_line_at_y (out start_iter, visible_rect.y, null);
                this.get_line_at_y (out end_iter, visible_rect.y + visible_rect.height, null);

                int first_line = start_iter.get_line ();
                int last_line = end_iter.get_line ();

                var error_tag = buf.get_tag_table ().lookup ("editor-error-line");
                var tab_data = this.get_data<EditorTabData> ("tab-data");

                int sel_start_line = 0;
                int sel_end_line = 0;
                bool has_tab_data = (tab_data != null);
                if (tab_data != null) {
                    sel_start_line = tab_data.selected_line_start;
                    sel_end_line = tab_data.selected_line_end;
                    if (sel_start_line > sel_end_line) {
                        int tmp = sel_start_line;
                        sel_start_line = sel_end_line;
                        sel_end_line = tmp;
                    }
                }

                float gutter_x = (float) (-gutter_w);
                float gutter_width_f = (float) gutter_w;

                for (int line_num = first_line; line_num <= last_line; line_num++) {
                    Gtk.TextIter l_start;
                    buf.get_iter_at_line (out l_start, line_num);

                    int line_y, line_h;
                    this.get_line_yrange (l_start, out line_y, out line_h);

                    float y_pos = (float) line_y;
                    float h_pos = (float) line_h;

                    if (error_tag != null && line_has_tag_in_range (buf, error_tag, line_num)) {
                        var err_rect = Graphene.Rect () {
                            origin = { gutter_x, y_pos },
                            size = { gutter_width_f, h_pos }
                        };
                        snapshot.append_color (error_gutter_bg, err_rect);
                    }

                    if (has_tab_data && line_num >= sel_start_line && line_num <= sel_end_line) {
                        var gutter_rect = Graphene.Rect () {
                            origin = { gutter_x, y_pos },
                            size = { gutter_width_f, h_pos }
                        };
                        snapshot.append_color (selected_gutter_bg, gutter_rect);
                    }
                }
            }
        }

        base.snapshot_layer (layer, snapshot);
    }
}

/* =========================================================================
 * 3. Main IDE Window
 * ========================================================================= */

public class RookieIdeWindow : Adw.ApplicationWindow {
    private Adw.TabView tab_view;
    private Adw.TabBar tab_bar;
#if HAVE_VTE
    private Vte.Terminal terminal;
#endif
    private Adw.WindowTitle title_widget;

    private Gtk.Paned main_paned;
    private Gtk.Paned editor_paned;
    private Gtk.Box file_sidebar;
    private Gtk.Label fm_dir_label;
    private Gtk.ListBox fm_list_box;
    private string current_fm_dir;
    private string? last_fm_rendered_dir = null;
    private bool initial_layout_applied = false;
    private bool user_adjusted_sidebar_split = false;
    private bool syncing_sidebar_position = false;

    private Gtk.Entry? line_label_entry = null;
    private Gtk.Entry? line_desc_entry = null;
    private Gtk.ListBox? line_labels_list = null;

    private Gtk.SearchEntry search_entry;

    private Gtk.Stack bottom_stack;
    private Gtk.ToggleButton status_tab_btn;
    private Gtk.ToggleButton compiler_tab_btn;
#if HAVE_VTE
    private Gtk.ToggleButton terminal_tab_btn;
#endif
    private bool syncing_bottom_tabs = false;

    private Gtk.TextView status_view;
    private Gtk.TextBuffer status_buffer;
    private Gtk.TextView compiler_view;
    private Gtk.TextBuffer compiler_buffer;
    private Gtk.TextTag? compiler_error_tag = null;

    private Gtk.Popover? token_popover = null;
    private Gtk.ListBox? token_list_box = null;
    private uint token_suggest_idle_id = 0;

    private GtkSource.LanguageManager lang_mgr;
    private GtkSource.StyleSchemeManager scheme_mgr;
    private GtkSource.StyleScheme? cached_scheme = null;
    private Gtk.CssProvider editor_font_provider;
    private Gtk.CssProvider vscode_theme_provider;
    private string? applied_vscode_style = null;
    private string? last_editor_font_css = null;

    private Gtk.Revealer cmd_revealer;
    private Gtk.Label active_lang_label;
    private Gtk.Entry compile_entry;
    private Gtk.Entry make_entry;
    private Gtk.Entry run_entry;
    private bool syncing_entries = false;
    private bool syncing_title = false;
    private bool restoring_session = false;
    private bool closing_tab = false;
    private bool force_closing_window = false;

    private uint save_session_timeout_id = 0;
    private uint save_cmds_timeout_id = 0;
    private uint save_profiles_timeout_id = 0;
    private uint save_labels_timeout_id = 0;
    private uint apply_profile_idle_id = 0;
    private string? last_session_snapshot = null;
    private string? last_cmds_snapshot = null;
    private string? last_profiles_snapshot = null;
    private string? last_labels_snapshot = null;

    private HashTable<string, HashTable<string, string>> build_cmds;
    private HashTable<string, ThemeProfile> profiles;
    private GenericArray<string> profile_order;
    private string active_profile_name = "VS Code Blue";
    private HashTable<string, GenericArray<LineLabelEntry>> saved_labels_by_key;

    private string config_path;
    private string session_path;
    private string profiles_path;
    private string labels_path;

    private const string[] ORDERED_SECTIONS = {
        "global", "c", "java", "js", "py", "rs", "html", "htm", "css"
    };

    private const LanguageFormat[] LANG_FORMATS = {
        {
            "HTML (.html)",
            "html",
            "index.html",
            "<!--\n * RookieIDE\n * %f\n *\n * Copyright 2026 %u\n -->\n<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n    <meta charset=\"UTF-8\">\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n    <title>%e</title>\n</head>\n<body>\n    <h1>Hello from RookieIDE</h1>\n</body>\n</html>\n"
        },
        {
            "CSS (.css)",
            "css",
            "styles.css",
            "/* RookieIDE\n * %f\n *\n * Copyright 2026 %u\n */\n\n* {\n    box-sizing: border-box;\n}\n\nbody {\n    margin: 0;\n    font-family: system-ui, sans-serif;\n}\n"
        },
        {
            "Java (.java)",
            "java",
            "Main.java",
            "/*\n * RookieIDE\n * %f\n *\n * Copyright 2026 %u\n */\n\npublic class %e {\n    public static void main(String[] args) {\n        System.out.println(\"Hello from RookieIDE!\");\n    }\n}\n"
        },
        {
            "JavaScript (.js)",
            "js",
            "script.js",
            "/*\n * RookieIDE\n * %f\n *\n * Copyright 2026 %u\n */\n\n\"use strict\";\n\nfunction main() {\n    console.log(\"Hello from RookieIDE!\");\n}\n\nmain();\n"
        },
        {
            "C (.c)",
            "c",
            "main.c",
            "/*\n * RookieIDE\n * %f\n *\n * Copyright 2026 %u\n */\n\n#include <stdio.h>\n\nint main(void) {\n    printf(\"Hello from RookieIDE!\\n\");\n    return 0;\n}\n"
        },
        {
            "Python (.py)",
            "py",
            "main.py",
            "# RookieIDE\n# %f\n#\n# Copyright 2026 %u\n\n\ndef main() -> None:\n    print(\"Hello from RookieIDE!\")\n\n\nif __name__ == \"__main__\":\n    main()\n"
        },
        {
            "Rust (.rs)",
            "rs",
            "main.rs",
            "/*\n * RookieIDE\n * %f\n *\n * Copyright 2026 %u\n */\n\nfn main() {\n    println!(\"Hello from RookieIDE!\");\n}\n"
        },
        {
            "Plain Text",
            "",
            "untitled.txt",
            "RookieIDE\n%f\n\nCopyright 2026 %u\n\n"
        }
    };

    public RookieIdeWindow (Adw.Application app) {
        Object (
            application: app,
            icon_name: "org.gnome.RookieIDE",
            default_width: 1200,
            default_height: 780
        );

        lang_mgr = GtkSource.LanguageManager.get_default ();
        scheme_mgr = GtkSource.StyleSchemeManager.get_default ();
        saved_labels_by_key = new HashTable<string, GenericArray<LineLabelEntry>> (str_hash, str_equal);

        string home = Environment.get_home_dir () ?? Environment.get_tmp_dir ();
        current_fm_dir = home;
        string config_dir = Path.build_filename (home, ".config", "rookie-ide");
        config_path = Path.build_filename (config_dir, "commands.conf");
        session_path = Path.build_filename (config_dir, "session.conf");
        profiles_path = Path.build_filename (config_dir, "profiles.conf");
        labels_path = Path.build_filename (config_dir, "line_labels.conf");

        build_cmds = new HashTable<string, HashTable<string, string>> (str_hash, str_equal);
        load_default_commands ();
        load_user_commands ();

        profiles = new HashTable<string, ThemeProfile> (str_hash, str_equal);
        profile_order = new GenericArray<string> ();
        load_default_profiles ();
        load_user_profiles ();
        load_user_line_labels ();

        build_ui ();
        apply_active_profile_now ();
        setup_shortcuts ();
        restore_session ();
        tab_bar.set_view (tab_view);
        refresh_active_tab_state ();
        sync_file_manager_dir_from_active_tab ();
#if HAVE_VTE
        start_shell ();
#endif

        this.map.connect (() => {
            Idle.add (() => {
                apply_startup_splits (true);
                if (tab_bar != null && tab_bar.get_width () > 0) {
                    sync_all_tab_glows ();
                }
                return Source.REMOVE;
            });
        });

        append_status ("RookieIDE ready (Profile: %s).".printf (active_profile_name));

        this.close_request.connect (() => {
            if (!force_closing_window && has_any_dirty_tab ()) {
                prompt_close_window_with_dirty_tabs ();
                return true;
            }
            cleanup_and_exit ();
            return false;
        });
    }

    private void cleanup_and_exit () {
        if (apply_profile_idle_id != 0) {
            Source.remove (apply_profile_idle_id);
            apply_profile_idle_id = 0;
        }
        if (token_suggest_idle_id != 0) {
            Source.remove (token_suggest_idle_id);
            token_suggest_idle_id = 0;
        }
        if (token_popover != null) {
            token_popover.unparent ();
            token_popover = null;
            token_list_box = null;
        }
        flush_pending_saves ();
        clear_log_buffers ();
    }

    /* =========================================================================
     * 4. Line Labels (Persistent Storage, Sidebar List & Dialogs)
     * ========================================================================= */

    private string escape_label_str (string raw) {
        return raw.replace ("\\", "\\\\").replace ("\n", "\\n").replace ("\r", "\\r");
    }

    private string unescape_label_str (string raw) {
        var sb = new StringBuilder ();
        for (int i = 0; i < raw.length; i++) {
            char c = raw[i];
            if (c == '\\' && i + 1 < raw.length) {
                char nxt = raw[i + 1];
                if (nxt == 'n') { sb.append_c ('\n'); i++; }
                else if (nxt == 'r') { sb.append_c ('\r'); i++; }
                else if (nxt == '\\') { sb.append_c ('\\'); i++; }
                else { sb.append_c (c); }
            } else {
                sb.append_c (c);
            }
        }
        return sb.str;
    }

    private string get_tab_storage_key (EditorTabData tab_data, Adw.TabPage? page = null) {
        if (tab_data.file != null) {
            string? p = tab_data.file.get_path ();
            if (p != null && p != "") {
                return "file:" + p;
            }
        }
        var target_page = page ?? tab_view.get_selected_page ();
        string raw = target_page != null ? target_page.get_title ().replace ("*", "").strip () : "Untitled";
        return "tab:" + (raw != "" ? raw : "Untitled");
    }

    private void load_user_line_labels () {
        if (!GLib.File.new_for_path (labels_path).query_exists ()) {
            return;
        }

        try {
            string content;
            FileUtils.get_contents (labels_path, out content);

            string? cur_key = null;
            GenericArray<LineLabelEntry>? cur_arr = null;
            int cur_line = -1;
            string cur_label = "";
            string cur_desc = "";
            bool has_line = false;
            bool has_label = false;
            bool has_desc = false;

            ProfileSyncAction flush_item = () => {
                if (cur_arr != null && (has_line || has_label || has_desc) && cur_line >= 0) {
                    string name = cur_label.strip ();
                    if (name == "") {
                        name = (cur_line + 1).to_string ();
                    }
                    cur_arr.add (new LineLabelEntry (cur_line, name, cur_desc.strip ()));
                }
                cur_line = -1;
                cur_label = "";
                cur_desc = "";
                has_line = false;
                has_label = false;
                has_desc = false;
            };

            foreach (string raw_line in content.split ("\n")) {
                string line = raw_line.strip ();
                if (line == "" || line.has_prefix ("#") || line.has_prefix (";")) {
                    continue;
                }
                if (line.has_prefix ("[") && line.has_suffix ("]")) {
                    flush_item ();
                    string sec_raw = line.substring (1, line.length - 2);
                    if (sec_raw.has_prefix ("file:")) {
                        cur_key = "file:" + unescape_label_str (sec_raw.substring (5));
                    } else if (sec_raw.has_prefix ("tab:")) {
                        cur_key = "tab:" + unescape_label_str (sec_raw.substring (4));
                    } else {
                        cur_key = unescape_label_str (sec_raw);
                    }
                    cur_arr = saved_labels_by_key.lookup (cur_key);
                    if (cur_arr == null) {
                        cur_arr = new GenericArray<LineLabelEntry> ();
                        saved_labels_by_key.insert (cur_key, cur_arr);
                    }
                    continue;
                }

                int eq = line.index_of_char ('=');
                if (eq <= 0 || cur_key == null || cur_arr == null) {
                    continue;
                }
                string k = line.substring (0, eq).strip ().down ();
                string v = line.substring (eq + 1);

                if (k == "line") {
                    if (has_line) {
                        flush_item ();
                    }
                    cur_line = int.parse (v.strip ()) - 1;
                    has_line = true;
                } else if (k == "label") {
                    if (has_label && !has_line) {
                        flush_item ();
                    }
                    cur_label = unescape_label_str (v.strip ());
                    has_label = true;
                } else if (k == "desc") {
                    if (has_desc && !has_line) {
                        flush_item ();
                    }
                    cur_desc = unescape_label_str (v.strip ());
                    has_desc = true;
                }
            }
            flush_item ();
        } catch (Error e) {
            warning ("Failed to load line labels: %s", e.message);
        }
    }

    private void sync_tab_labels_to_store (EditorTabData tab_data, Adw.TabPage? page = null) {
        string key = get_tab_storage_key (tab_data, page);
        var copy = new GenericArray<LineLabelEntry> ();
        for (int i = 0; i < tab_data.line_labels.length; i++) {
            var item = tab_data.line_labels[i];
            copy.add (new LineLabelEntry (item.line_index, item.label, item.description));
        }
        if (copy.length > 0) {
            saved_labels_by_key.insert (key, copy);
        } else {
            saved_labels_by_key.remove (key);
        }
    }

    private void apply_saved_labels_to_tab (EditorTabData tab_data, Adw.TabPage? page = null) {
        string key = get_tab_storage_key (tab_data, page);
        var stored = saved_labels_by_key.lookup (key);
        if (stored == null && tab_data.file == null) {
            var target_page = page ?? tab_view.get_selected_page ();
            string raw = target_page != null ? target_page.get_title ().replace ("*", "").strip () : "Untitled";
            stored = saved_labels_by_key.lookup ("tab:" + raw);
        }
        if (stored == null) {
            return;
        }
        tab_data.line_labels = new GenericArray<LineLabelEntry> ();
        for (int i = 0; i < stored.length; i++) {
            var item = stored[i];
            tab_data.line_labels.add (new LineLabelEntry (item.line_index, item.label, item.description));
        }
        tab_data.view.queue_draw ();
    }

    private void save_user_line_labels_now () {
        int n = tab_view != null ? tab_view.get_n_pages () : 0;
        for (int i = 0; i < n; i++) {
            Adw.TabPage? p;
            var data = get_tab_data_at (i, out p);
            if (data != null) {
                sync_tab_labels_to_store (data, p);
            }
        }

        var sb = new StringBuilder ();
        sb.append ("# RookieIDE Saved Line Labels\n\n");

        saved_labels_by_key.foreach ((storage_key, arr) => {
            if (arr == null || arr.length == 0) {
                return;
            }
            string section_header;
            if (storage_key.has_prefix ("file:")) {
                section_header = "[file:%s]".printf (escape_label_str (storage_key.substring (5)));
            } else if (storage_key.has_prefix ("tab:")) {
                section_header = "[tab:%s]".printf (escape_label_str (storage_key.substring (4)));
            } else {
                section_header = "[%s]".printf (escape_label_str (storage_key));
            }
            sb.append_printf ("%s\n", section_header);
            for (int i = 0; i < arr.length; i++) {
                var item = arr[i];
                sb.append_printf ("line=%d\n", item.line_index + 1);
                sb.append_printf ("label=%s\n", escape_label_str (item.label));
                sb.append_printf ("desc=%s\n", escape_label_str (item.description));
            }
            sb.append ("\n");
        });

        if (last_labels_snapshot != null && last_labels_snapshot == sb.str) {
            return;
        }

        try {
            DirUtils.create_with_parents (Path.get_dirname (labels_path), 0755);
            FileUtils.set_contents (labels_path, sb.str);
            last_labels_snapshot = sb.str;
        } catch (Error e) {
            warning ("Failed to save line labels: %s", e.message);
        }
    }

    private void schedule_save_line_labels () {
        if (save_labels_timeout_id != 0) {
            Source.remove (save_labels_timeout_id);
        }
        save_labels_timeout_id = Timeout.add (150, () => {
            save_labels_timeout_id = 0;
            save_user_line_labels_now ();
            return Source.REMOVE;
        });
    }

    private void jump_to_line_index (int line_index) {
        var data = get_current_tab_data ();
        if (data == null || line_index < 0) {
            return;
        }

        int total_lines = data.buffer.get_line_count ();
        int target_line = line_index.clamp (0, int.max (0, total_lines - 1));

        Gtk.TextIter iter;
        data.buffer.get_iter_at_line (out iter, target_line);
        data.buffer.place_cursor (iter);
        data.view.scroll_to_iter (iter, 0.2, true, 0.0, 0.2);
        update_selected_gutter_lines (data);
        data.view.grab_focus ();
    }

    private void add_current_line_label () {
        var data = get_current_tab_data ();
        if (data == null || line_label_entry == null) {
            return;
        }

        string typed_name = line_label_entry.get_text ().strip ();
        string typed_desc = line_desc_entry != null ? line_desc_entry.get_text ().strip () : "";

        Gtk.TextIter cursor_iter;
        data.buffer.get_iter_at_mark (out cursor_iter, data.buffer.get_insert ());
        int line_idx = cursor_iter.get_line ();

        if (typed_name == "") {
            typed_name = (line_idx + 1).to_string ();
        }

        data.set_label_for_line (line_idx, typed_name, typed_desc);
        line_label_entry.set_text ("");
        if (line_desc_entry != null) {
            line_desc_entry.set_text ("");
        }

        sync_tab_labels_to_store (data, tab_view.get_selected_page ());
        data.view.queue_draw ();
        refresh_line_labels_list ();
        schedule_save_line_labels ();
        append_status ("Saved label \"%s\" at line %d.".printf (typed_name, line_idx + 1));
    }

    private void open_edit_line_label_dialog (EditorTabData tab_data, LineLabelEntry entry) {
        var dialog = new Adw.Window ();
        dialog.set_transient_for (this);
        dialog.set_modal (true);
        dialog.set_default_size (420, 290);
        dialog.set_title ("Edit Line Label (Line %d)".printf (entry.line_index + 1));

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        dialog.set_content (vbox);

        var d_header = new Adw.HeaderBar ();
        var save_btn = new Gtk.Button.with_label ("Save");
        save_btn.add_css_class ("suggested-action");
        d_header.pack_end (save_btn);
        vbox.append (d_header);

        var clamp = new Adw.Clamp ();
        clamp.set_margin_top (16);
        clamp.set_margin_bottom (16);
        clamp.set_margin_start (16);
        clamp.set_margin_end (16);
        vbox.append (clamp);

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Line %d Label Details".printf (entry.line_index + 1));
        clamp.set_child (group);

        var name_row = new Adw.EntryRow ();
        name_row.set_title ("Label Name");
        name_row.set_text (entry.label);
        group.add (name_row);

        var desc_row = new Adw.EntryRow ();
        desc_row.set_title ("Description");
        desc_row.set_text (entry.description);
        group.add (desc_row);

        ProfileSyncAction commit_edit = () => {
            string updated_name = name_row.get_text ().strip ();
            if (updated_name == "") {
                updated_name = (entry.line_index + 1).to_string ();
            }
            entry.label = updated_name;
            entry.description = desc_row.get_text ().strip ();
            sync_tab_labels_to_store (tab_data, tab_view.get_selected_page ());
            tab_data.view.queue_draw ();
            refresh_line_labels_list ();
            schedule_save_line_labels ();
            append_status ("Updated label \"%s\" on line %d.".printf (entry.label, entry.line_index + 1));
            dialog.close ();
        };

        save_btn.clicked.connect (() => commit_edit ());
        name_row.entry_activated.connect (() => commit_edit ());
        desc_row.entry_activated.connect (() => commit_edit ());

        dialog.present ();
    }

    private void open_line_label_dialog (EditorTabData tab_data, int line_idx) {
        var existing = tab_data.find_label_for_line (line_idx);
        if (existing != null) {
            open_edit_line_label_dialog (tab_data, existing);
            return;
        }

        var dialog = new Adw.Window ();
        dialog.set_transient_for (this);
        dialog.set_modal (true);
        dialog.set_default_size (400, 270);
        dialog.set_title ("Line %d Label".printf (line_idx + 1));

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        dialog.set_content (vbox);

        var d_header = new Adw.HeaderBar ();
        var save_btn = new Gtk.Button.with_label ("Save");
        save_btn.add_css_class ("suggested-action");
        d_header.pack_end (save_btn);
        vbox.append (d_header);

        var clamp = new Adw.Clamp ();
        clamp.set_margin_top (16);
        clamp.set_margin_bottom (16);
        clamp.set_margin_start (16);
        clamp.set_margin_end (16);
        vbox.append (clamp);

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Label on Line %d".printf (line_idx + 1));
        clamp.set_child (group);

        var label_row = new Adw.EntryRow ();
        label_row.set_title ("Label Name");
        label_row.set_text ((line_idx + 1).to_string ());
        group.add (label_row);

        var desc_row = new Adw.EntryRow ();
        desc_row.set_title ("Description (optional)");
        desc_row.set_text ("");
        group.add (desc_row);

        ProfileSyncAction commit_label = () => {
            string txt = label_row.get_text ().strip ();
            if (txt == "") {
                txt = (line_idx + 1).to_string ();
            }
            tab_data.set_label_for_line (line_idx, txt, desc_row.get_text ().strip ());
            sync_tab_labels_to_store (tab_data, tab_view.get_selected_page ());
            tab_data.view.queue_draw ();
            refresh_line_labels_list ();
            schedule_save_line_labels ();
            append_status ("Saved line label \"%s\" at line %d.".printf (txt, line_idx + 1));
            dialog.close ();
        };

        save_btn.clicked.connect (() => commit_label ());
        label_row.entry_activated.connect (() => commit_label ());
        desc_row.entry_activated.connect (() => commit_label ());

        dialog.present ();
    }

    private void refresh_line_labels_list () {
        if (line_labels_list == null) {
            return;
        }

        var child = line_labels_list.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            line_labels_list.remove (child);
            child = next;
        }

        var data = get_current_tab_data ();
        if (data == null) {
            return;
        }

        for (int i = 0; i < data.line_labels.length; i++) {
            var entry = data.line_labels[i];
            int target_line = entry.line_index;

            var row = new Gtk.ListBoxRow ();
            var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            hbox.set_margin_top (4);
            hbox.set_margin_bottom (4);
            hbox.set_margin_start (6);
            hbox.set_margin_end (4);

            var line_badge = new Gtk.Label ("L%d".printf (entry.line_index + 1));
            line_badge.add_css_class ("caption");
            line_badge.add_css_class ("dim-label");
            line_badge.set_valign (Gtk.Align.START);
            line_badge.set_margin_top (2);

            var text_vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
            text_vbox.set_hexpand (true);

            var name_lbl = new Gtk.Label (entry.label);
            name_lbl.add_css_class ("heading");
            name_lbl.set_xalign (0.0f);
            name_lbl.set_ellipsize (Pango.EllipsizeMode.END);
            text_vbox.append (name_lbl);

            if (entry.description != "") {
                var desc_lbl = new Gtk.Label (entry.description);
                desc_lbl.add_css_class ("caption");
                desc_lbl.add_css_class ("dim-label");
                desc_lbl.set_xalign (0.0f);
                desc_lbl.set_ellipsize (Pango.EllipsizeMode.END);
                text_vbox.append (desc_lbl);
                row.set_tooltip_text ("Line %d: %s — %s".printf (entry.line_index + 1, entry.label, entry.description));
            } else {
                row.set_tooltip_text ("Line %d: %s".printf (entry.line_index + 1, entry.label));
            }

            var edit_btn = new Gtk.Button.from_icon_name ("document-edit-symbolic");
            edit_btn.add_css_class ("flat");
            edit_btn.set_valign (Gtk.Align.CENTER);
            edit_btn.set_tooltip_text ("Edit label name and description");
            edit_btn.clicked.connect (() => open_edit_line_label_dialog (data, entry));

            var rm_btn = new Gtk.Button.from_icon_name ("window-close-symbolic");
            rm_btn.add_css_class ("flat");
            rm_btn.set_valign (Gtk.Align.CENTER);
            rm_btn.set_tooltip_text ("Remove label");
            rm_btn.clicked.connect (() => {
                data.remove_label_for_line (target_line);
                sync_tab_labels_to_store (data, tab_view.get_selected_page ());
                data.view.queue_draw ();
                refresh_line_labels_list ();
                schedule_save_line_labels ();
            });

            hbox.append (line_badge);
            hbox.append (text_vbox);
            hbox.append (edit_btn);
            hbox.append (rm_btn);
            row.set_child (hbox);
            row.set_data<int> ("target-line", target_line);
            line_labels_list.append (row);
        }
    }

    private void attach_gutter_label_gesture (EditorTabData tab_data) {
        var click = new Gtk.GestureClick ();
        click.set_button (0);
        click.pressed.connect ((n_press, x, y) => {
            var left_gutter = tab_data.view.get_gutter (Gtk.TextWindowType.LEFT);
            int gutter_w = left_gutter != null ? left_gutter.get_width () : 0;
            if (gutter_w <= 0 || x > gutter_w) {
                return;
            }

            int buf_x, buf_y;
            tab_data.view.window_to_buffer_coords (Gtk.TextWindowType.WIDGET, (int) x, (int) y, out buf_x, out buf_y);
            Gtk.TextIter iter;
            tab_data.view.get_line_at_y (out iter, buf_y, null);
            int line_idx = iter.get_line ();

            uint btn = click.get_current_button ();
            if (btn == Gdk.BUTTON_SECONDARY || n_press >= 2) {
                open_line_label_dialog (tab_data, line_idx);
            } else if (btn == Gdk.BUTTON_PRIMARY) {
                var existing = tab_data.find_label_for_line (line_idx);
                if (existing != null && existing.description != "") {
                    append_status ("Line %d [%s]: %s".printf (line_idx + 1, existing.label, existing.description));
                }
            }
        });
        tab_data.view.add_controller (click);
    }

    private void update_selected_gutter_lines (EditorTabData tab_data) {
        Gtk.TextIter sel_start, sel_end;
        int start_line, end_line;

        if (tab_data.buffer.get_selection_bounds (out sel_start, out sel_end)) {
            start_line = sel_start.get_line ();
            end_line = sel_end.get_line ();
            if (sel_end.starts_line () && end_line > start_line) {
                end_line--;
            }
        } else {
            Gtk.TextIter cursor_iter;
            tab_data.buffer.get_iter_at_mark (out cursor_iter, tab_data.buffer.get_insert ());
            start_line = cursor_iter.get_line ();
            end_line = start_line;
        }

        if (tab_data.selected_line_start != start_line || tab_data.selected_line_end != end_line) {
            tab_data.selected_line_start = start_line;
            tab_data.selected_line_end = end_line;
            tab_data.view.queue_draw ();
        }
    }

    /* =========================================================================
     * 5. Tabs, Uncompiled Glow & Dirty Close Prompts
     * ========================================================================= */

    private EditorTabData? get_tab_data_at (int index, out Adw.TabPage? out_page) {
        out_page = tab_view.get_nth_page (index);
        return out_page != null ? out_page.get_data<EditorTabData> ("tab-data") : null;
    }

    private EditorTabData? get_current_tab_data () {
        var page = tab_view.get_selected_page ();
        return page != null ? page.get_data<EditorTabData> ("tab-data") : null;
    }

    private void apply_glow_to_matching_widgets (Gtk.Widget root, string clean_title, bool glowing) {
        if (root is Gtk.Label) {
            var lbl = (Gtk.Label) root;
            string lbl_clean = lbl.get_label ().replace ("*", "").strip ();
            if (lbl_clean == clean_title) {
                if (glowing) {
                    lbl.add_css_class ("uncompiled-glow");
                } else {
                    lbl.remove_css_class ("uncompiled-glow");
                }
            }
        }

        var child = root.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            apply_glow_to_matching_widgets (child, clean_title, glowing);
            child = next;
        }
    }

    private void set_tab_uncompiled_glow (Adw.TabPage? page, EditorTabData? data, bool glowing) {
        if (data == null) {
            return;
        }
        data.needs_compile = glowing;

        if (page != null && tab_bar != null) {
            string clean_title = page.get_title ().replace ("*", "").strip ();
            if (clean_title != "") {
                apply_glow_to_matching_widgets (tab_bar, clean_title, glowing);
                tab_bar.queue_draw ();
            }
        }
    }

    private void sync_all_tab_glows () {
        if (tab_view == null || tab_bar == null) {
            return;
        }
        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data != null && page != null) {
                string clean_title = page.get_title ().replace ("*", "").strip ();
                if (clean_title != "") {
                    apply_glow_to_matching_widgets (tab_bar, clean_title, data.needs_compile);
                }
            }
        }
        tab_bar.queue_draw ();
    }

    private void clear_uncompiled_glow_for_target (string dir, string filename) {
        string target_path = Path.build_filename (dir, filename);
        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data == null || page == null) {
                continue;
            }
            string? tab_path = data.file != null ? data.file.get_path () : null;
            bool matches = (tab_path != null && tab_path == target_path) ||
                           (data.file == null && page == tab_view.get_selected_page ());
            if (matches) {
                set_tab_uncompiled_glow (page, data, false);
            }
        }
    }

    private bool has_any_dirty_tab () {
        if (tab_view == null) {
            return false;
        }
        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? _p;
            var data = get_tab_data_at (i, out _p);
            if (data != null && data.dirty) {
                return true;
            }
        }
        return false;
    }

    private void finalize_tab_close (Adw.TabPage page, EditorTabData? data) {
        closing_tab = true;
        if (data != null) {
            sync_tab_labels_to_store (data, page);
            schedule_save_line_labels ();
            detach_token_popover_if_parent (data.view);
        }
        tab_view.close_page_finish (page, true);
        if (tab_view.get_n_pages () == 0) {
            create_new_tab (null, "Untitled", "");
        }
        closing_tab = false;
        refresh_active_tab_state ();
        sync_all_tab_glows ();
        schedule_save_session ();
    }

    private void prompt_close_dirty_page (Adw.TabPage page, EditorTabData data) {
        string raw_title = page.get_title ().replace ("*", "").strip ();
        if (raw_title == "") {
            raw_title = "Untitled";
        }

        var dialog = new Adw.AlertDialog (
            "Save Changes to \"%s\"?".printf (raw_title),
            "Your changes will be permanently lost if you don't save them before closing."
        );
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("discard", "Discard");
        dialog.add_response ("save", "Save");
        dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("save");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp == "discard") {
                data.dirty = false;
                data.needs_compile = false;
                finalize_tab_close (page, data);
                return;
            }

            if (resp == "save") {
                if (data.file != null) {
                    if (write_tab_to_disk (page, data, false)) {
                        finalize_tab_close (page, data);
                    } else {
                        tab_view.close_page_finish (page, false);
                    }
                    return;
                }

                var save_dialog = new Gtk.FileDialog ();
                save_dialog.set_initial_name (raw_title);
                save_dialog.save.begin (this, null, (_obj, res) => {
                    try {
                        GLib.File? chosen = save_dialog.save.end (res);
                        if (chosen != null) {
                            data.file = chosen;
                            if (write_tab_to_disk (page, data, false)) {
                                finalize_tab_close (page, data);
                                return;
                            }
                        }
                    } catch (Error e) {
                        if (!(e is Gtk.DialogError.DISMISSED)) {
                            append_status ("Save error: %s".printf (e.message));
                            show_status_dialog ("Save Error", e.message);
                        }
                    }
                    tab_view.close_page_finish (page, false);
                });
                return;
            }

            tab_view.close_page_finish (page, false);
        });

        dialog.present (this);
    }

    private void save_next_dirty_or_close_window (int start_index) {
        int n = tab_view.get_n_pages ();
        for (int i = start_index; i < n; i++) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data != null && page != null && data.dirty) {
                if (data.file != null) {
                    if (!write_tab_to_disk (page, data, false)) {
                        return;
                    }
                } else {
                    tab_view.set_selected_page (page);
                    string raw_title = page.get_title ().replace ("*", "").strip ();
                    if (raw_title == "") {
                        raw_title = "Untitled";
                    }

                    var save_dialog = new Gtk.FileDialog ();
                    save_dialog.set_initial_name (raw_title);
                    save_dialog.save.begin (this, null, (_obj, res) => {
                        try {
                            GLib.File? chosen = save_dialog.save.end (res);
                            if (chosen != null) {
                                data.file = chosen;
                                if (write_tab_to_disk (page, data, false)) {
                                    save_next_dirty_or_close_window (i + 1);
                                }
                            }
                        } catch (Error e) {
                            if (!(e is Gtk.DialogError.DISMISSED)) {
                                append_status ("Save error: %s".printf (e.message));
                                show_status_dialog ("Save Error", e.message);
                            }
                        }
                    });
                    return;
                }
            }
        }

        force_closing_window = true;
        this.close ();
    }

    private void prompt_close_window_with_dirty_tabs () {
        var dirty_names = new GenericArray<string> ();
        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data != null && page != null && data.dirty) {
                string clean = page.get_title ().replace ("*", "").strip ();
                dirty_names.add (clean != "" ? clean : "Untitled");
            }
        }

        string body;
        if (dirty_names.length == 1) {
            body = "\"%s\" has unsaved changes. Do you want to save before leaving?".printf (dirty_names[0]);
        } else {
            var list_sb = new StringBuilder ();
            for (int i = 0; i < dirty_names.length; i++) {
                list_sb.append_printf ("\n• %s", dirty_names[i]);
            }
            body = "The following files have unsaved changes:%s".printf (list_sb.str);
        }

        var dialog = new Adw.AlertDialog ("Save Changes Before Leaving?", body);
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("discard", "Discard");
        dialog.add_response ("save", "Save");
        dialog.set_response_appearance ("discard", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_response_appearance ("save", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("save");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp == "discard") {
                force_closing_window = true;
                this.close ();
            } else if (resp == "save") {
                save_next_dirty_or_close_window (0);
            }
        });

        dialog.present (this);
    }

    private void create_new_tab (GLib.File? file, string tab_title, string initial_text) {
        var prof = get_active_profile ();
        var buffer = new GtkSource.Buffer (null);
        buffer.highlight_syntax = true;
        if (cached_scheme != null) {
            buffer.set_style_scheme (cached_scheme);
        }
        buffer.set_language (lang_mgr.guess_language (tab_title, null));

        var view = new ErrorLineSourceView.with_buffer (buffer);
        view.add_css_class ("rookie-editor");
        view.show_line_numbers = prof.show_line_numbers;
        view.auto_indent = true;
        view.insert_spaces_instead_of_tabs = true;
        view.tab_width = (uint) prof.tab_width.clamp (2, 8);
        view.monospace = true;
        view.set_vexpand (true);
        view.set_hexpand (true);

        var scroll = new Gtk.ScrolledWindow ();
        scroll.set_child (view);

        var tab_data = new EditorTabData (file, buffer, view);
        view.set_data<EditorTabData> ("tab-data", tab_data);
        attach_gutter_label_gesture (tab_data);
        attach_autoclose_and_autofill (tab_data);

        buffer.notify["cursor-position"].connect (() => update_selected_gutter_lines (tab_data));
        buffer.mark_set.connect ((_iter, mark) => {
            if (mark == buffer.get_insert () || mark == buffer.get_selection_bound ()) {
                update_selected_gutter_lines (tab_data);
            }
        });

        var page = tab_view.append (scroll);
        page.set_title (tab_title);
        page.set_live_thumbnail (true);
        page.set_data<EditorTabData> ("tab-data", tab_data);
        apply_saved_labels_to_tab (tab_data, page);

        syncing_title = true;
        buffer.set_text (initial_text);
        update_selected_gutter_lines (tab_data);
        syncing_title = false;

        buffer.changed.connect (() => {
            update_selected_gutter_lines (tab_data);
            if (syncing_title || restoring_session) {
                return;
            }
            tab_data.dirty = true;
            string base_title = page.get_title ();
            if (!base_title.has_prefix ("*")) {
                syncing_title = true;
                page.set_title ("*" + base_title);
                syncing_title = false;
            }
            set_tab_uncompiled_glow (page, tab_data, true);
        });

        page.notify["title"].connect (() => {
            if (!syncing_title) {
                sync_all_tab_glows ();
            }
        });

        tab_view.set_selected_page (page);
        if (!restoring_session) {
            refresh_active_tab_state ();
        }
    }

    private void refresh_active_tab_state () {
        var page = tab_view.get_selected_page ();
        var data = get_current_tab_data ();

        if (data != null && data.file != null) {
            title_widget.set_title (data.file.get_basename () ?? "Untitled");
            title_widget.set_subtitle (data.file.get_parent ()?.get_path () ?? "");
        } else {
            string raw_title = page != null ? page.get_title ().replace ("*", "") : "Untitled";
            title_widget.set_title (raw_title);
            title_widget.set_subtitle ("Unsaved buffer");
        }

        if (data != null) {
            update_selected_gutter_lines (data);
        }

        refresh_inline_command_bar ();
        refresh_line_labels_list ();
    }

    /* =========================================================================
     * 6. Themes, CSS, Profiles & Terminal Styling
     * ========================================================================= */

    [CCode (cname = "gtk_style_context_add_provider_for_display")]
    private extern static void gtk_add_provider_for_display (
        Gdk.Display display,
        Gtk.StyleProvider provider,
        uint priority
    );

    private void install_ui_css () {
        var display = Gdk.Display.get_default ();
        if (display == null) {
            return;
        }

        var provider = new Gtk.CssProvider ();
        provider.load_from_string ("""
            entry.search-no-match,
            searchentry.search-no-match {
                border-color: #e01b24;
                outline-color: #e01b24;
                background-color: alpha(#e01b24, 0.14);
                color: #ff6b72;
            }
            .bottom-tab-strip {
                padding: 4px 8px;
                border-bottom: 1px solid alpha(@window_fg_color, 0.12);
            }
            button.bottom-tab-btn {
                padding: 3px 10px;
                border-radius: 6px;
                font-weight: 500;
            }
            button.bottom-tab-active {
                background-color: alpha(@accent_bg_color, 0.24);
                color: @accent_fg_color;
                font-weight: 600;
            }
            .fm-sidebar {
                background-color: alpha(@view_bg_color, 0.55);
            }
            .tabbar tabbox,
            .tabbar tabboxchild,
            .tabbar tab {
                min-width: 0;
                min-height: 0;
            }
            .tabbar tabboxchild {
                margin: 0;
                padding: 0;
            }
            .tabbar tab.uncompiled-glow,
            .tabbar tab.uncompiled-glow label,
            label.uncompiled-glow {
                color: #ff4d5a;
                text-shadow: 0 0 6px rgba(255, 59, 78, 0.9), 0 0 14px rgba(224, 27, 36, 0.65);
                font-weight: 700;
            }
        """);

        gtk_add_provider_for_display (
            display,
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );

        editor_font_provider = new Gtk.CssProvider ();
        gtk_add_provider_for_display (
            display,
            editor_font_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );

        vscode_theme_provider = new Gtk.CssProvider ();
        gtk_add_provider_for_display (
            display,
            vscode_theme_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2
        );
    }

    private string sanitize_profile_name (string raw) {
        return raw.strip ().replace ("[", "").replace ("]", "").replace ("=", "").strip ();
    }

    private ThemeProfile get_active_profile () {
        var prof = profiles.lookup (active_profile_name);
        if (prof == null) {
            prof = profiles.lookup ("VS Code Blue");
        }
        if (prof == null) {
            prof = profiles.lookup ("Default");
        }
        if (prof == null) {
            prof = new ThemeProfile ("Default");
            register_profile (prof);
        }
        return prof;
    }

    private void register_profile (ThemeProfile prof) {
        if (!profiles.contains (prof.name)) {
            profile_order.add (prof.name);
        }
        profiles.insert (prof.name, prof);
    }

    private void load_default_profiles () {
        register_profile (new ThemeProfile (
            "VS Code Blue", "dark", "auto", "Monospace 11", "vscode-blue", "Monospace 10", 4, true, true, true
        ));
        register_profile (new ThemeProfile (
            "Default", "dark", "auto", "Monospace 11", "vscode-blue", "Monospace 10", 4, true, true, true
        ));
        register_profile (new ThemeProfile (
            "VS Code Dark", "dark", "auto", "Monospace 11", "vscode-dark", "Monospace 10", 4, true, true, true
        ));
        register_profile (new ThemeProfile (
            "Dark Focus", "dark", "Adwaita-dark", "Monospace 11", "dracula", "Monospace 10", 4, true, true, true
        ));
        register_profile (new ThemeProfile (
            "Light Paper", "light", "Adwaita", "Monospace 11", "adwaita-light", "Monospace 10", 4, true, true, true
        ));
    }

    private void load_user_profiles () {
        if (!GLib.File.new_for_path (profiles_path).query_exists ()) {
            save_user_profiles_now ();
            return;
        }

        try {
            string content;
            FileUtils.get_contents (profiles_path, out content);

            ThemeProfile? current = null;
            foreach (string raw_line in content.split ("\n")) {
                string line = raw_line.strip ();
                if (line == "" || line.has_prefix ("#") || line.has_prefix (";")) {
                    continue;
                }
                if (line.has_prefix ("[") && line.has_suffix ("]")) {
                    string sec = sanitize_profile_name (line.substring (1, line.length - 2));
                    if (sec == "" || sec.down () == "general") {
                        current = null;
                    } else {
                        current = profiles.lookup (sec);
                        if (current == null) {
                            current = new ThemeProfile (sec);
                            register_profile (current);
                        }
                    }
                    continue;
                }

                int eq = line.index_of_char ('=');
                if (eq <= 0) {
                    continue;
                }
                string key = line.substring (0, eq).strip ().down ();
                string val = line.substring (eq + 1).strip ();

                if (current == null) {
                    if (key == "active" && val != "") {
                        active_profile_name = sanitize_profile_name (val);
                    }
                } else {
                    switch (key) {
                        case "app_theme":
                            current.app_theme = val;
                            break;
                        case "style_scheme":
                            current.style_scheme = val;
                            break;
                        case "editor_font":
                            if (val != "") current.editor_font = val;
                            break;
                        case "terminal_theme":
                            current.terminal_theme = val;
                            break;
                        case "terminal_font":
                            if (val != "") current.terminal_font = val;
                            break;
                        case "tab_width":
                            current.tab_width = int.parse (val).clamp (2, 8);
                            break;
                        case "show_line_numbers":
                            current.show_line_numbers = (val.down () == "true" || val == "1");
                            break;
                        case "file_manager_enabled":
                            current.file_manager_enabled = (val.down () == "true" || val == "1");
                            break;
                        case "autoclose_enabled":
                            current.autoclose_enabled = (val.down () == "true" || val == "1");
                            break;
                    }
                }
            }

            if (!profiles.contains (active_profile_name)) {
                var fallback = new ThemeProfile (active_profile_name);
                register_profile (fallback);
            }
        } catch (Error e) {
            warning ("Failed to load profiles: %s", e.message);
        }
    }

    private void save_user_profiles_now () {
        var sb = new StringBuilder ();
        sb.append ("# RookieIDE Theme Profiles\n\n");
        sb.append ("[general]\n");
        sb.append_printf ("active=%s\n\n", active_profile_name);

        for (int i = 0; i < profile_order.length; i++) {
            string name = profile_order[i];
            var prof = profiles.lookup (name);
            if (prof == null) {
                continue;
            }
            sb.append_printf ("[%s]\n", prof.name);
            sb.append_printf ("app_theme=%s\n", prof.app_theme);
            sb.append_printf ("style_scheme=%s\n", prof.style_scheme);
            sb.append_printf ("editor_font=%s\n", prof.editor_font);
            sb.append_printf ("terminal_theme=%s\n", prof.terminal_theme);
            sb.append_printf ("terminal_font=%s\n", prof.terminal_font);
            sb.append_printf ("tab_width=%d\n", prof.tab_width);
            sb.append_printf ("show_line_numbers=%s\n", prof.show_line_numbers ? "true" : "false");
            sb.append_printf ("file_manager_enabled=%s\n", prof.file_manager_enabled ? "true" : "false");
            sb.append_printf ("autoclose_enabled=%s\n\n", prof.autoclose_enabled ? "true" : "false");
        }

        if (last_profiles_snapshot != null && last_profiles_snapshot == sb.str) {
            return;
        }

        try {
            DirUtils.create_with_parents (Path.get_dirname (profiles_path), 0755);
            FileUtils.set_contents (profiles_path, sb.str);
            last_profiles_snapshot = sb.str;
        } catch (Error e) {
            warning ("Failed to save profiles: %s", e.message);
        }
    }

    private void schedule_save_profiles () {
        if (save_profiles_timeout_id != 0) {
            Source.remove (save_profiles_timeout_id);
        }
        save_profiles_timeout_id = Timeout.add (200, () => {
            save_profiles_timeout_id = 0;
            save_user_profiles_now ();
            return Source.REMOVE;
        });
    }

    private void schedule_apply_active_profile () {
        if (apply_profile_idle_id != 0) {
            return;
        }
        apply_profile_idle_id = Idle.add (() => {
            apply_profile_idle_id = 0;
            apply_active_profile_now ();
            return Source.REMOVE;
        });
    }

    private void apply_vscode_css (string theme_id) {
        if (vscode_theme_provider == null || applied_vscode_style == theme_id) {
            return;
        }
        applied_vscode_style = theme_id;

        if (theme_id == "vscode-blue") {
            vscode_theme_provider.load_from_string ("""
                window,
                headerbar,
                .tabbar,
                .fm-sidebar,
                paned > separator {
                    background-color: #102036;
                    color: #d6e8ff;
                    border-color: #243b5c;
                }
                .tabbar tab {
                    background-color: #102036;
                    color: #93b3dc;
                }
                .tabbar tab:selected {
                    background-color: #162a47;
                    color: #ffffff;
                    border-bottom: 2px solid #38a5ff;
                }
                textview.rookie-editor,
                textview.rookie-editor > text,
                textview.rookie-editor gutter {
                    background-color: #14263d;
                    color: #d6e8ff;
                }
                textview {
                    background-color: #102036;
                    color: #d6e8ff;
                }
                button.suggested-action {
                    background-color: #1f6feb;
                    color: #ffffff;
                }
                button.suggested-action:hover {
                    background-color: #38a5ff;
                    color: #0b131e;
                }
                button.bottom-tab-active {
                    background-color: alpha(#38a5ff, 0.24);
                    color: #6ec3ff;
                    border-bottom: 2px solid #38a5ff;
                }
            """);
            return;
        }

        if (theme_id == "vscode-dark") {
            vscode_theme_provider.load_from_string ("""
                window,
                headerbar,
                .tabbar,
                .fm-sidebar,
                paned > separator {
                    background-color: #181818;
                    color: #cccccc;
                    border-color: #2b2b2b;
                }
                .tabbar tab {
                    background-color: #181818;
                    color: #9d9d9d;
                }
                .tabbar tab:selected {
                    background-color: #1f1f1f;
                    color: #ffffff;
                    border-bottom: 2px solid #0078d4;
                }
                textview.rookie-editor,
                textview.rookie-editor > text,
                textview.rookie-editor gutter {
                    background-color: #1f1f1f;
                    color: #cccccc;
                }
                textview {
                    background-color: #181818;
                    color: #cccccc;
                }
                button.suggested-action {
                    background-color: #0078d4;
                    color: #ffffff;
                }
                button.suggested-action:hover {
                    background-color: #026ec1;
                }
                button.bottom-tab-active {
                    background-color: alpha(#0078d4, 0.28);
                    color: #ffffff;
                    border-bottom: 2px solid #0078d4;
                }
            """);
            return;
        }

        vscode_theme_provider.load_from_string ("");
    }

    private void refresh_cached_style_scheme () {
        var prof = get_active_profile ();
        string target_id = prof.style_scheme;
        if (target_id == "auto" || target_id == "") {
            bool is_dark = Adw.StyleManager.get_default ().dark;
            target_id = is_dark ? "Adwaita-dark" : "Adwaita";
        }
        var scheme = scheme_mgr.get_scheme (target_id);
        if (scheme == null) {
            bool is_dark = Adw.StyleManager.get_default ().dark;
            scheme = scheme_mgr.get_scheme (is_dark ? "Adwaita-dark" : "Adwaita");
        }
        if (scheme == null) {
            foreach (string id in scheme_mgr.get_scheme_ids ()) {
                scheme = scheme_mgr.get_scheme (id);
                if (scheme != null) {
                    break;
                }
            }
        }
        cached_scheme = scheme;
    }

    private void apply_active_profile_now () {
        var prof = get_active_profile ();

        var style_mgr = Adw.StyleManager.get_default ();
        Adw.ColorScheme desired_scheme;
        switch (prof.app_theme) {
            case "light":
                desired_scheme = Adw.ColorScheme.FORCE_LIGHT;
                break;
            case "dark":
                desired_scheme = Adw.ColorScheme.FORCE_DARK;
                break;
            default:
                desired_scheme = Adw.ColorScheme.DEFAULT;
                break;
        }
        if (style_mgr.get_color_scheme () != desired_scheme) {
            style_mgr.set_color_scheme (desired_scheme);
        }

        apply_vscode_css (prof.terminal_theme);

        if (file_sidebar != null && main_paned != null) {
            bool was_visible = file_sidebar.get_visible ();
            file_sidebar.set_visible (prof.file_manager_enabled);
            if (prof.file_manager_enabled) {
                refresh_file_manager (false);
                if (!was_visible) {
                    sync_sidebar_split_ratio (false);
                }
            }
        }

        if (editor_font_provider != null) {
            var desc = Pango.FontDescription.from_string (prof.editor_font);
            string family = desc.get_family () ?? "Monospace";
            int size_pts = desc.get_size () / Pango.SCALE;
            if (size_pts <= 0) {
                size_pts = 11;
            }
            string escaped_family = family.replace ("\"", "\\\"");
            string css = "textview.rookie-editor { font-family: \"%s\", monospace; font-size: %dpt; }".printf (
                escaped_family,
                size_pts
            );
            if (last_editor_font_css != css) {
                editor_font_provider.load_from_string (css);
                last_editor_font_css = css;
            }
        }

        refresh_cached_style_scheme ();
        int n = tab_view != null ? tab_view.get_n_pages () : 0;
        for (int i = 0; i < n; i++) {
            Adw.TabPage? _p;
            var data = get_tab_data_at (i, out _p);
            if (data != null) {
                if (cached_scheme != null && data.buffer.get_style_scheme () != cached_scheme) {
                    data.buffer.set_style_scheme (cached_scheme);
                }
                data.view.set_tab_width ((uint) prof.tab_width.clamp (2, 8));
                data.view.set_show_line_numbers (prof.show_line_numbers);
                data.view.set_monospace (true);
                data.view.queue_draw ();
            }
        }

#if HAVE_VTE
        apply_terminal_profile (prof);
#endif
        sync_all_tab_glows ();
    }

#if HAVE_VTE
    private Gdk.RGBA parse_rgba (string hex) {
        var c = Gdk.RGBA ();
        c.parse (hex);
        return c;
    }

    private void set_terminal_palette (
        string fg_hex,
        string bg_hex,
        string[] hex_16,
        out Gdk.RGBA fg,
        out Gdk.RGBA bg,
        Gdk.RGBA[] palette
    ) {
        fg = parse_rgba (fg_hex);
        bg = parse_rgba (bg_hex);
        for (int i = 0; i < 16 && i < hex_16.length; i++) {
            palette[i] = parse_rgba (hex_16[i]);
        }
    }

    private void apply_terminal_profile (ThemeProfile prof) {
        if (terminal == null) {
            return;
        }

        terminal.set_font (Pango.FontDescription.from_string (prof.terminal_font));

        Gdk.RGBA fg;
        Gdk.RGBA bg;
        Gdk.RGBA[] palette = new Gdk.RGBA[16];

        switch (prof.terminal_theme) {
            case "vscode-blue":
                set_terminal_palette (
                    "#d6e8ff",
                    "#14263d",
                    {
                        "#102036", "#ff6b72", "#4ec9b0", "#e5c07b",
                        "#38a5ff", "#c586c0", "#4fc1ff", "#d6e8ff",
                        "#5c7699", "#ff858d", "#6be0c8", "#f2d28b",
                        "#6ec3ff", "#d99fd6", "#7ad4ff", "#ffffff"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;

            case "vscode-dark":
                set_terminal_palette (
                    "#cccccc",
                    "#1f1f1f",
                    {
                        "#181818", "#f85149", "#2ea043", "#d29922",
                        "#0078d4", "#bc8cff", "#39c5cf", "#cccccc",
                        "#6e7681", "#ff7b72", "#3fb950", "#e3b341",
                        "#58a6ff", "#d2a8ff", "#56d4dd", "#ffffff"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;

            case "adwaita-light":
                set_terminal_palette (
                    "#1e1e1e",
                    "#ffffff",
                    {
                        "#241f31", "#c01c28", "#2ec27e", "#f5c211",
                        "#1e78e4", "#9841bb", "#0ab9dc", "#c0bfbc",
                        "#5e5c64", "#ed333b", "#57e389", "#f8e45c",
                        "#51a1ff", "#c061cb", "#4fd2fd", "#f6f5f4"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;

            case "solarized-dark":
                set_terminal_palette (
                    "#839496",
                    "#002b36",
                    {
                        "#073642", "#dc322f", "#859900", "#b58900",
                        "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                        "#002b36", "#cb4b16", "#586e75", "#657b83",
                        "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;

            case "dracula":
                set_terminal_palette (
                    "#f8f8f2",
                    "#282a36",
                    {
                        "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                        "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                        "#d6acff", "#ff92df", "#a4ffff", "#ffffff"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;

            case "monokai":
                set_terminal_palette (
                    "#f8f8f2",
                    "#272822",
                    {
                        "#272822", "#f92672", "#a6e22e", "#f4bf75",
                        "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                        "#75715e", "#f92672", "#a6e22e", "#f4bf75",
                        "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;

            default:
                set_terminal_palette (
                    "#deddda",
                    "#1e1e1e",
                    {
                        "#241f31", "#c01c28", "#2ec27e", "#f5c211",
                        "#1e78e4", "#9841bb", "#0ab9dc", "#c0bfbc",
                        "#5e5c64", "#ed333b", "#57e389", "#f8e45c",
                        "#51a1ff", "#c061cb", "#4fd2fd", "#f6f5f4"
                    },
                    out fg,
                    out bg,
                    palette
                );
                break;
        }

        terminal.set_colors (fg, bg, palette);
    }
#endif

    private string[] build_profile_names_array () {
        string[] names = new string[profile_order.length];
        for (int i = 0; i < profile_order.length; i++) {
            names[i] = profile_order[i];
        }
        return names;
    }

    private void open_theme_profiles_dialog () {
        var dialog = new Adw.Window ();
        dialog.set_transient_for (this);
        dialog.set_modal (true);
        dialog.set_default_size (540, 650);
        dialog.set_title ("Themes, Plugins & Profiles");

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        dialog.set_content (vbox);

        var d_header = new Adw.HeaderBar ();
        var done_btn = new Gtk.Button.with_label ("Done");
        done_btn.add_css_class ("suggested-action");
        done_btn.clicked.connect (() => dialog.close ());
        d_header.pack_end (done_btn);
        vbox.append (d_header);

        var scroll = new Gtk.ScrolledWindow ();
        scroll.set_vexpand (true);
        vbox.append (scroll);

        var clamp = new Adw.Clamp ();
        clamp.set_margin_top (16);
        clamp.set_margin_bottom (18);
        clamp.set_margin_start (18);
        clamp.set_margin_end (18);
        scroll.set_child (clamp);

        var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
        clamp.set_child (content_box);

        var prof_group = new Adw.PreferencesGroup ();
        prof_group.set_title ("Theme Profiles");
        prof_group.set_description ("Switch between saved theme profiles or create a new one");
        content_box.append (prof_group);

        var profile_list_model = new Gtk.StringList (build_profile_names_array ());
        var profile_row = new Adw.ComboRow ();
        profile_row.set_title ("Active Profile");
        profile_row.set_model (profile_list_model);
        prof_group.add (profile_row);

        var new_prof_row = new Adw.EntryRow ();
        new_prof_row.set_title ("New Profile Name");
        var add_prof_btn = new Gtk.Button.with_label ("Create");
        add_prof_btn.set_valign (Gtk.Align.CENTER);
        add_prof_btn.add_css_class ("suggested-action");
        new_prof_row.add_suffix (add_prof_btn);
        prof_group.add (new_prof_row);

        var delete_row = new Adw.ActionRow ();
        delete_row.set_title ("Delete Current Profile");
        delete_row.set_subtitle ("Built-in Default and VS Code Blue profiles cannot be deleted");
        var delete_btn = new Gtk.Button.with_label ("Delete");
        delete_btn.set_valign (Gtk.Align.CENTER);
        delete_btn.add_css_class ("destructive-action");
        delete_row.add_suffix (delete_btn);
        prof_group.add (delete_row);

        var plugins_group = new Adw.PreferencesGroup ();
        plugins_group.set_title ("Plugins");
        plugins_group.set_description ("Enable or disable built-in editor extensions");
        content_box.append (plugins_group);

        var fm_plugin_row = new Adw.SwitchRow ();
        fm_plugin_row.set_title ("File Manager");
        fm_plugin_row.set_subtitle ("Browse current directory and manage files beside the editor");
        plugins_group.add (fm_plugin_row);

        var autoclose_plugin_row = new Adw.SwitchRow ();
        autoclose_plugin_row.set_title ("Bracket Autoclose & Snippet Autofill");
        autoclose_plugin_row.set_subtitle ("Auto-pair (), [], {}, quotes, expand Enter blocks, and expand Tab snippets");
        plugins_group.add (autoclose_plugin_row);

        var editor_group = new Adw.PreferencesGroup ();
        editor_group.set_title ("Window & Editor Theme");
        content_box.append (editor_group);

        string[] app_theme_labels = { "Follow System", "Light", "Dark" };
        string[] app_theme_ids = { "system", "light", "dark" };
        var app_theme_row = new Adw.ComboRow ();
        app_theme_row.set_title ("Window Color Scheme");
        app_theme_row.set_model (new Gtk.StringList (app_theme_labels));
        editor_group.add (app_theme_row);

        var scheme_ids_arr = new GenericArray<string> ();
        var scheme_labels_arr = new GenericArray<string> ();
        scheme_ids_arr.add ("auto");
        scheme_labels_arr.add ("Auto (Match Window)");
        foreach (string id in scheme_mgr.get_scheme_ids ()) {
            var s = scheme_mgr.get_scheme (id);
            scheme_ids_arr.add (id);
            scheme_labels_arr.add (s != null ? s.get_name () : id);
        }
        string[] scheme_ids = new string[scheme_ids_arr.length];
        string[] scheme_labels = new string[scheme_labels_arr.length];
        for (int i = 0; i < scheme_ids_arr.length; i++) {
            scheme_ids[i] = scheme_ids_arr[i];
            scheme_labels[i] = scheme_labels_arr[i];
        }

        var style_scheme_row = new Adw.ComboRow ();
        style_scheme_row.set_title ("Syntax Highlighting Theme");
        style_scheme_row.set_model (new Gtk.StringList (scheme_labels));
        editor_group.add (style_scheme_row);

        var editor_font_row = new Adw.EntryRow ();
        editor_font_row.set_title ("Editor Font (e.g. Monospace 11)");
        editor_group.add (editor_font_row);

        var tab_width_row = new Adw.SpinRow.with_range (2, 8, 1);
        tab_width_row.set_title ("Tab Width");
        editor_group.add (tab_width_row);

        var line_num_row = new Adw.SwitchRow ();
        line_num_row.set_title ("Show Line Numbers");
        editor_group.add (line_num_row);

        var term_group = new Adw.PreferencesGroup ();
        term_group.set_title ("Terminal Theme");
        content_box.append (term_group);

        string[] term_theme_labels = {
            "VS Code Blue",
            "VS Code Dark",
            "Adwaita Dark",
            "Adwaita Light",
            "Solarized Dark",
            "Dracula",
            "Monokai"
        };
        string[] term_theme_ids = {
            "vscode-blue",
            "vscode-dark",
            "adwaita-dark",
            "adwaita-light",
            "solarized-dark",
            "dracula",
            "monokai"
        };
        var term_theme_row = new Adw.ComboRow ();
        term_theme_row.set_title ("Terminal Palette");
        term_theme_row.set_model (new Gtk.StringList (term_theme_labels));
        term_group.add (term_theme_row);

        var term_font_row = new Adw.EntryRow ();
        term_font_row.set_title ("Terminal Font (e.g. Monospace 10)");
        term_group.add (term_font_row);

        bool syncing_dialog = false;

        ProfileSyncAction sync_controls_only = () => {
            syncing_dialog = true;
            var prof = get_active_profile ();

            uint active_idx = 0;
            for (uint i = 0; i < profile_order.length; i++) {
                if (profile_order[i] == prof.name) {
                    active_idx = i;
                    break;
                }
            }
            if (profile_row.get_selected () != active_idx) {
                profile_row.set_selected (active_idx);
            }

            delete_btn.set_sensitive (prof.name != "Default" && prof.name != "VS Code Blue");

            if (fm_plugin_row.get_active () != prof.file_manager_enabled) {
                fm_plugin_row.set_active (prof.file_manager_enabled);
            }
            if (autoclose_plugin_row.get_active () != prof.autoclose_enabled) {
                autoclose_plugin_row.set_active (prof.autoclose_enabled);
            }

            uint app_idx = 0;
            for (uint i = 0; i < app_theme_ids.length; i++) {
                if (app_theme_ids[i] == prof.app_theme) {
                    app_idx = i;
                    break;
                }
            }
            if (app_theme_row.get_selected () != app_idx) {
                app_theme_row.set_selected (app_idx);
            }

            uint scheme_idx = 0;
            for (uint i = 0; i < scheme_ids.length; i++) {
                if (scheme_ids[i] == prof.style_scheme) {
                    scheme_idx = i;
                    break;
                }
            }
            if (style_scheme_row.get_selected () != scheme_idx) {
                style_scheme_row.set_selected (scheme_idx);
            }

            if (editor_font_row.get_text () != prof.editor_font) {
                editor_font_row.set_text (prof.editor_font);
            }
            if ((int) tab_width_row.get_value () != prof.tab_width) {
                tab_width_row.set_value (prof.tab_width);
            }
            if (line_num_row.get_active () != prof.show_line_numbers) {
                line_num_row.set_active (prof.show_line_numbers);
            }

            uint term_idx = 0;
            for (uint i = 0; i < term_theme_ids.length; i++) {
                if (term_theme_ids[i] == prof.terminal_theme) {
                    term_idx = i;
                    break;
                }
            }
            if (term_theme_row.get_selected () != term_idx) {
                term_theme_row.set_selected (term_idx);
            }
            if (term_font_row.get_text () != prof.terminal_font) {
                term_font_row.set_text (prof.terminal_font);
            }

            syncing_dialog = false;
        };

        ProfileSyncAction refresh_profile_model_and_controls = () => {
            syncing_dialog = true;
            string[] names = build_profile_names_array ();
            profile_list_model.splice (0, profile_list_model.get_n_items (), names);
            syncing_dialog = false;
            sync_controls_only ();
        };

        ProfileSyncAction apply_dialog_changes = () => {
            if (syncing_dialog) {
                return;
            }
            var prof = get_active_profile ();

            prof.file_manager_enabled = fm_plugin_row.get_active ();
            prof.autoclose_enabled = autoclose_plugin_row.get_active ();

            uint app_idx = app_theme_row.get_selected ();
            if (app_idx < app_theme_ids.length) {
                prof.app_theme = app_theme_ids[app_idx];
            }

            uint scheme_idx = style_scheme_row.get_selected ();
            if (scheme_idx < scheme_ids.length) {
                prof.style_scheme = scheme_ids[scheme_idx];
            }

            string e_font = editor_font_row.get_text ().strip ();
            if (e_font != "") {
                prof.editor_font = e_font;
            }

            prof.tab_width = (int) tab_width_row.get_value ();
            prof.show_line_numbers = line_num_row.get_active ();

            uint term_idx = term_theme_row.get_selected ();
            if (term_idx < term_theme_ids.length) {
                prof.terminal_theme = term_theme_ids[term_idx];
            }

            string t_font = term_font_row.get_text ().strip ();
            if (t_font != "") {
                prof.terminal_font = t_font;
            }

            schedule_apply_active_profile ();
            schedule_save_profiles ();
        };

        profile_row.notify["selected"].connect (() => {
            if (syncing_dialog) {
                return;
            }
            uint idx = profile_row.get_selected ();
            if (idx < profile_order.length) {
                active_profile_name = profile_order[idx];
                sync_controls_only ();
                schedule_apply_active_profile ();
                schedule_save_profiles ();
                append_status ("Switched to profile: %s".printf (active_profile_name));
            }
        });

        add_prof_btn.clicked.connect (() => {
            string new_name = sanitize_profile_name (new_prof_row.get_text ());
            if (new_name == "" || new_name.down () == "general") {
                return;
            }

            var base_prof = get_active_profile ();
            var copy = new ThemeProfile (
                new_name,
                base_prof.app_theme,
                base_prof.style_scheme,
                base_prof.editor_font,
                base_prof.terminal_theme,
                base_prof.terminal_font,
                base_prof.tab_width,
                base_prof.show_line_numbers,
                base_prof.file_manager_enabled,
                base_prof.autoclose_enabled
            );
            register_profile (copy);
            active_profile_name = new_name;
            new_prof_row.set_text ("");

            refresh_profile_model_and_controls ();
            schedule_apply_active_profile ();
            schedule_save_profiles ();
            append_status ("Created profile: %s".printf (new_name));
        });

        delete_btn.clicked.connect (() => {
            if (active_profile_name == "Default" || active_profile_name == "VS Code Blue") {
                return;
            }
            string removed = active_profile_name;
            profiles.remove (removed);
            for (int i = 0; i < profile_order.length; i++) {
                if (profile_order[i] == removed) {
                    profile_order.remove_index (i);
                    break;
                }
            }
            active_profile_name = "VS Code Blue";
            refresh_profile_model_and_controls ();
            schedule_apply_active_profile ();
            schedule_save_profiles ();
            append_status ("Deleted profile: %s".printf (removed));
        });

        fm_plugin_row.notify["active"].connect (() => apply_dialog_changes ());
        autoclose_plugin_row.notify["active"].connect (() => apply_dialog_changes ());
        app_theme_row.notify["selected"].connect (() => apply_dialog_changes ());
        style_scheme_row.notify["selected"].connect (() => apply_dialog_changes ());
        editor_font_row.changed.connect (() => apply_dialog_changes ());
        tab_width_row.notify["value"].connect (() => apply_dialog_changes ());
        line_num_row.notify["active"].connect (() => apply_dialog_changes ());
        term_theme_row.notify["selected"].connect (() => apply_dialog_changes ());
        term_font_row.changed.connect (() => apply_dialog_changes ());

        sync_controls_only ();
        dialog.present ();
    }

    /* =========================================================================
     * 7. Editor Helpers (Search, Error Lines, Autoclose, Snippets & Tokens)
     * ========================================================================= */

    private void set_search_no_match (bool no_match) {
        if (search_entry == null) {
            return;
        }
        if (no_match) {
            search_entry.add_css_class ("search-no-match");
        } else {
            search_entry.remove_css_class ("search-no-match");
        }
    }

    private void go_to_search_match (bool backward = false, bool from_current_pos = true, bool log_jump = false) {
        var data = get_current_tab_data ();
        if (data == null || search_entry == null) {
            return;
        }

        string needle = search_entry.get_text ();
        if (needle == "") {
            set_search_no_match (false);
            return;
        }

        Gtk.TextIter start_iter, end_iter, match_start, match_end;
        data.buffer.get_bounds (out start_iter, out end_iter);

        Gtk.TextIter sel_start, sel_end;
        bool has_sel = data.buffer.get_selection_bounds (out sel_start, out sel_end);

        Gtk.TextIter cursor_iter;
        data.buffer.get_iter_at_mark (out cursor_iter, data.buffer.get_insert ());

        Gtk.TextIter primary_from;
        Gtk.TextIter wrap_from;
        if (!backward) {
            primary_from = from_current_pos ? (has_sel ? sel_end : cursor_iter) : start_iter;
            wrap_from = start_iter;
        } else {
            primary_from = from_current_pos ? (has_sel ? sel_start : cursor_iter) : end_iter;
            wrap_from = end_iter;
        }

        var flags = Gtk.TextSearchFlags.CASE_INSENSITIVE;
        bool found = backward
            ? primary_from.backward_search (needle, flags, out match_start, out match_end, null)
            : primary_from.forward_search (needle, flags, out match_start, out match_end, null);

        if (!found && primary_from.compare (wrap_from) != 0) {
            found = backward
                ? wrap_from.backward_search (needle, flags, out match_start, out match_end, null)
                : wrap_from.forward_search (needle, flags, out match_start, out match_end, null);
        }

        if (!found) {
            set_search_no_match (true);
            if (log_jump) {
                append_status ("No match for \"%s\"".printf (needle));
            }
            return;
        }

        set_search_no_match (false);
        Gtk.TextIter line_start;
        data.buffer.get_iter_at_line (out line_start, match_start.get_line ());
        data.buffer.place_cursor (line_start);
        data.buffer.select_range (match_start, match_end);
        data.view.scroll_to_iter (line_start, 0.2, true, 0.0, 0.2);

        if (log_jump) {
            append_status ("Jumped to line %d for \"%s\"".printf (match_start.get_line () + 1, needle));
        }
    }

    private Gtk.TextTag ensure_editor_error_line_tag (Gtk.TextBuffer buf) {
        var tag = buf.get_tag_table ().lookup ("editor-error-line");
        if (tag != null) {
            return tag;
        }
        var fg = Gdk.RGBA ();
        fg.parse ("#ff8b94");
        return buf.create_tag (
            "editor-error-line",
            "foreground-rgba", fg
        );
    }

    private void clear_error_highlights_all_tabs () {
        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? _p;
            var data = get_tab_data_at (i, out _p);
            if (data != null) {
                var tag = data.buffer.get_tag_table ().lookup ("editor-error-line");
                if (tag != null) {
                    Gtk.TextIter start_iter, end_iter;
                    data.buffer.get_bounds (out start_iter, out end_iter);
                    data.buffer.remove_tag (tag, start_iter, end_iter);
                }
                data.view.queue_draw ();
            }
        }
    }

    private void highlight_error_line_in_editor (string? file_path, int one_based_line) {
        if (one_based_line <= 0) {
            return;
        }
        int line_idx = one_based_line - 1;

        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data == null || page == null) {
                continue;
            }

            string? tab_path = data.file != null ? data.file.get_path () : null;
            bool matches_file = (file_path == null || file_path == "")
                ? (page == tab_view.get_selected_page ())
                : (tab_path != null && (tab_path == file_path || Path.get_basename (tab_path) == Path.get_basename (file_path)));

            if (!matches_file) {
                continue;
            }

            int total_lines = data.buffer.get_line_count ();
            if (line_idx >= total_lines) {
                continue;
            }

            Gtk.TextIter line_start, line_end;
            data.buffer.get_iter_at_line (out line_start, line_idx);
            line_end = line_start;
            if (!line_end.ends_line () && !line_end.forward_to_line_end ()) {
                data.buffer.get_end_iter (out line_end);
            }

            var tag = ensure_editor_error_line_tag (data.buffer);
            data.buffer.apply_tag (tag, line_start, line_end);
            data.view.queue_draw ();
        }
    }

    private void highlight_error_lines_from_output (string output) {
        foreach (string raw_line in output.split ("\n")) {
            if (!line_looks_like_error (raw_line)) {
                continue;
            }
            int first_colon = raw_line.index_of_char (':');
            while (first_colon > 0) {
                int second_colon = raw_line.index_of_char (':', first_colon + 1);
                if (second_colon > first_colon + 1) {
                    string num_str = raw_line.substring (first_colon + 1, second_colon - first_colon - 1).strip ();
                    int parsed_line = int.parse (num_str);
                    if (parsed_line > 0) {
                        string candidate_file = raw_line.substring (0, first_colon).strip ();
                        highlight_error_line_in_editor (candidate_file, parsed_line);
                        break;
                    }
                }
                first_colon = raw_line.index_of_char (':', first_colon + 1);
            }
        }
    }

    private void schedule_token_suggestions (EditorTabData tab_data) {
        if (token_suggest_idle_id != 0) {
            Source.remove (token_suggest_idle_id);
        }
        token_suggest_idle_id = Idle.add (() => {
            token_suggest_idle_id = 0;
            update_token_suggestions (tab_data);
            return Source.REMOVE;
        });
    }

    private void ensure_token_popover (EditorTabData tab_data) {
        if (token_popover != null && token_list_box != null) {
            return;
        }

        token_popover = new Gtk.Popover ();
        token_popover.set_autohide (false);
        token_popover.set_has_arrow (false);

        token_list_box = new Gtk.ListBox ();
        token_list_box.set_selection_mode (Gtk.SelectionMode.SINGLE);
        token_list_box.row_activated.connect ((row) => {
            string? token = row.get_data<string> ("token-text");
            if (token != null && token != "") {
                insert_suggested_token (token);
            }
        });

        var scroll = new Gtk.ScrolledWindow ();
        scroll.set_min_content_width (220);
        scroll.set_max_content_height (180);
        scroll.set_propagate_natural_height (true);
        scroll.set_child (token_list_box);

        token_popover.set_child (scroll);
        token_popover.set_parent (tab_data.view);
    }

    private void hide_token_popover () {
        if (token_popover != null && token_popover.get_visible ()) {
            token_popover.popdown ();
        }
    }

    private void detach_token_popover_if_parent (Gtk.Widget view_widget) {
        if (token_popover != null && token_popover.get_parent () == view_widget) {
            hide_token_popover ();
            token_popover.unparent ();
            token_popover = null;
            token_list_box = null;
        }
    }

    private string get_word_prefix_at_cursor (Gtk.TextBuffer buffer, out Gtk.TextIter word_start, out Gtk.TextIter cursor_iter) {
        buffer.get_iter_at_mark (out cursor_iter, buffer.get_insert ());
        word_start = cursor_iter;

        while (word_start.backward_char ()) {
            Gtk.TextIter check = word_start;
            check.forward_char ();
            string s = buffer.get_text (word_start, check, false);
            if (s.length != 1) {
                word_start.forward_char ();
                break;
            }
            char c = s[0];
            bool is_ident = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                            (c >= '0' && c <= '9') || c == '_';
            if (!is_ident) {
                word_start.forward_char ();
                break;
            }
        }

        return buffer.get_text (word_start, cursor_iter, false);
    }

    private string[] merge_token_arrays (string[] first, string[] second) {
        string[] combined = new string[first.length + second.length];
        for (int i = 0; i < first.length; i++) combined[i] = first[i];
        for (int j = 0; j < second.length; j++) combined[first.length + j] = second[j];
        return combined;
    }

    private string[] get_matching_tokens (string prefix, string ext) {
        string lower_prefix = prefix.down ();
        string[] base_tokens = {
            "printf", "private", "public", "protected", "package", "pass",
            "println!", "print", "parse", "pointer", "param", "return",
            "if", "else", "for", "while", "switch", "case", "break", "continue",
            "void", "int", "float", "double", "char", "bool", "string",
            "class", "struct", "enum", "interface", "static", "const", "var",
            "function", "def", "fn", "main", "import", "include", "true", "false", "null"
        };

        if (ext == "c") {
            string[] c_extra = { "printf", "scanf", "malloc", "free", "sizeof", "typedef", "NULL" };
            base_tokens = merge_token_arrays (base_tokens, c_extra);
        } else if (ext == "java") {
            string[] java_extra = { "System.out.println", "public static void main", "String", "override", "new" };
            base_tokens = merge_token_arrays (base_tokens, java_extra);
        } else if (ext == "py") {
            string[] py_extra = { "print", "pass", "elif", "lambda", "self", "None", "True", "False" };
            base_tokens = merge_token_arrays (base_tokens, py_extra);
        } else if (ext == "js") {
            string[] js_extra = { "console.log", "async", "await", "let", "const", "export", "import" };
            base_tokens = merge_token_arrays (base_tokens, js_extra);
        }

        var matches = new GenericArray<string> ();
        var seen = new GenericSet<string> (str_hash, str_equal);
        foreach (string tok in base_tokens) {
            if (tok.down ().has_prefix (lower_prefix) && !seen.contains (tok)) {
                seen.add (tok);
                matches.add (tok);
            }
        }

        string[] result = new string[matches.length];
        for (int i = 0; i < matches.length; i++) {
            result[i] = matches[i];
        }
        return result;
    }

    private string get_line_leading_indent (Gtk.TextBuffer buffer, Gtk.TextIter word_start) {
        Gtk.TextIter line_start;
        buffer.get_iter_at_line (out line_start, word_start.get_line ());
        string prefix_before_word = buffer.get_text (line_start, word_start, false);

        var indent_sb = new StringBuilder ();
        for (int i = 0; i < prefix_before_word.length; i++) {
            char c = prefix_before_word[i];
            if (c == ' ' || c == '\t') {
                indent_sb.append_c (c);
            } else {
                break;
            }
        }
        return indent_sb.str;
    }

    private string get_completed_token_text (string token, string ext, string base_indent) {
        if (ext == "py") {
            if (token == "while" || token == "if") {
                return "%s :\n%s    ".printf (token, base_indent);
            }
            if (token == "for") {
                return "for  in :\n%s    ".printf (base_indent);
            }
            if (token == "def") {
                return "def ():\n%s    ".printf (base_indent);
            }
            if (token == "print") {
                return "print()";
            }
            return token;
        }

        switch (token) {
            case "while":
            case "if":
            case "switch":
            case "for":
                return "%s () {\n%s    \n%s}".printf (token, base_indent, base_indent);
            case "function":
                return "function () {\n%s    \n%s}".printf (base_indent, base_indent);
            case "printf":
            case "println!":
            case "print":
            case "scanf":
            case "console.log":
            case "System.out.println":
                return token + "()";
            default:
                return token;
        }
    }

    private int get_token_cursor_char_offset (string completed_text) {
        int open_paren = completed_text.index_of ("(");
        if (open_paren >= 0) {
            return completed_text.substring (0, open_paren).char_count () + 1;
        }
        return completed_text.char_count ();
    }

    private void update_token_suggestions (EditorTabData tab_data) {
        Gtk.TextIter word_start, cursor_iter;
        string prefix = get_word_prefix_at_cursor (tab_data.buffer, out word_start, out cursor_iter);
        if (prefix.length < 1) {
            hide_token_popover ();
            return;
        }

        string[] matches = get_matching_tokens (prefix, get_active_ext ());
        if (matches.length == 0) {
            hide_token_popover ();
            return;
        }

        ensure_token_popover (tab_data);
        if (token_popover == null || token_list_box == null) {
            return;
        }

        if (token_popover.get_parent () != tab_data.view) {
            token_popover.unparent ();
            token_popover.set_parent (tab_data.view);
        }

        var child = token_list_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            token_list_box.remove (child);
            child = next;
        }

        foreach (string tok in matches) {
            var row = new Gtk.ListBoxRow ();
            var lbl = new Gtk.Label (tok);
            lbl.set_xalign (0.0f);
            lbl.set_margin_top (4);
            lbl.set_margin_bottom (4);
            lbl.set_margin_start (8);
            lbl.set_margin_end (8);
            row.set_child (lbl);
            row.set_data<string> ("token-text", tok);
            token_list_box.append (row);
        }

        var first_row = token_list_box.get_row_at_index (0);
        if (first_row != null) {
            token_list_box.select_row (first_row);
        }

        Gdk.Rectangle rect;
        tab_data.view.get_iter_location (cursor_iter, out rect);
        int win_x, win_y;
        tab_data.view.buffer_to_window_coords (Gtk.TextWindowType.WIDGET, rect.x, rect.y + rect.height, out win_x, out win_y);
        Gdk.Rectangle anchor = { win_x, win_y, 1, 1 };
        token_popover.set_pointing_to (anchor);

        if (!token_popover.get_visible ()) {
            token_popover.popup ();
        }
    }

    private void insert_suggested_token (string token) {
        var tab_data = get_current_tab_data ();
        if (tab_data == null) {
            return;
        }

        Gtk.TextIter word_start, cursor_iter;
        get_word_prefix_at_cursor (tab_data.buffer, out word_start, out cursor_iter);
        int start_off = word_start.get_offset ();
        string base_indent = get_line_leading_indent (tab_data.buffer, word_start);

        string ext = get_active_ext ();
        string completed = get_completed_token_text (token, ext, base_indent);
        int cursor_offset = start_off + get_token_cursor_char_offset (completed);

        tab_data.buffer.begin_user_action ();
        tab_data.buffer.delete (ref word_start, ref cursor_iter);

        Gtk.TextIter ins_iter;
        tab_data.buffer.get_iter_at_offset (out ins_iter, start_off);
        tab_data.buffer.insert (ref ins_iter, completed, -1);

        Gtk.TextIter target_iter;
        tab_data.buffer.get_iter_at_offset (out target_iter, cursor_offset);
        tab_data.buffer.place_cursor (target_iter);
        tab_data.buffer.end_user_action ();

        hide_token_popover ();
        tab_data.view.grab_focus ();
    }

    private void attach_autoclose_and_autofill (EditorTabData tab_data) {
        var key_ctrl = new Gtk.EventControllerKey ();
        key_ctrl.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);

        key_ctrl.key_pressed.connect ((keyval, _keycode, state) => {
            if (!get_active_profile ().autoclose_enabled) {
                return false;
            }

            var mods = state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK);
            if (mods != 0) {
                return false;
            }

            if (token_popover != null && token_popover.get_visible () && token_list_box != null) {
                if (keyval == Gdk.Key.Escape) {
                    hide_token_popover ();
                    return true;
                }
                if (keyval == Gdk.Key.Down) {
                    var sel = token_list_box.get_selected_row ();
                    int idx = sel != null ? sel.get_index () + 1 : 0;
                    var next_row = token_list_box.get_row_at_index (idx);
                    if (next_row != null) {
                        token_list_box.select_row (next_row);
                    }
                    return true;
                }
                if (keyval == Gdk.Key.Up) {
                    var sel = token_list_box.get_selected_row ();
                    int idx = sel != null ? sel.get_index () - 1 : 0;
                    if (idx >= 0) {
                        var prev_row = token_list_box.get_row_at_index (idx);
                        if (prev_row != null) {
                            token_list_box.select_row (prev_row);
                        }
                    }
                    return true;
                }
                if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter || keyval == Gdk.Key.Tab || keyval == Gdk.Key.KP_Tab) {
                    var sel = token_list_box.get_selected_row ();
                    if (sel != null) {
                        string? tok = sel.get_data<string> ("token-text");
                        if (tok != null && tok != "") {
                            insert_suggested_token (tok);
                            return true;
                        }
                    }
                }
            }

            if (keyval == Gdk.Key.Tab || keyval == Gdk.Key.KP_Tab) {
                if (try_expand_snippet (tab_data)) {
                    hide_token_popover ();
                    return true;
                }
                return false;
            }

            if (keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) {
                hide_token_popover ();
                if (try_expand_pair_newline (tab_data)) {
                    return true;
                }
                return false;
            }

            if (keyval == Gdk.Key.BackSpace) {
                if (try_remove_empty_pair (tab_data)) {
                    return true;
                }
                schedule_token_suggestions (tab_data);
                return false;
            }

            uint ch = Gdk.keyval_to_unicode (keyval);
            if (ch == 0) {
                return false;
            }

            string typed = ((unichar) ch).to_string ();
            string? closing = get_closing_pair (typed);

            Gtk.TextIter iter;
            tab_data.buffer.get_iter_at_mark (out iter, tab_data.buffer.get_insert ());

            if (is_closing_char (typed)) {
                Gtk.TextIter next_iter = iter;
                if (next_iter.forward_char ()) {
                    string next_str = tab_data.buffer.get_text (iter, next_iter, false);
                    if (next_str == typed) {
                        tab_data.buffer.place_cursor (next_iter);
                        return true;
                    }
                }
            }

            if (typed == "\"" || typed == "'" || typed == "`") {
                Gtk.TextIter prev_iter = iter;
                if (prev_iter.backward_char ()) {
                    string prev_str = tab_data.buffer.get_text (prev_iter, iter, false);
                    if (prev_str.length == 1) {
                        char pc = prev_str[0];
                        bool prev_is_word = (pc >= 'a' && pc <= 'z') || (pc >= 'A' && pc <= 'Z') ||
                                            (pc >= '0' && pc <= '9') || pc == '_' || pc == typed[0];
                        if (prev_is_word) {
                            return false;
                        }
                    }
                }
            }

            if (closing != null) {
                hide_token_popover ();
                tab_data.buffer.begin_user_action ();
                string pair = typed + closing;
                tab_data.buffer.insert (ref iter, pair, -1);

                Gtk.TextIter cursor_back = iter;
                cursor_back.backward_char ();
                if (typed == "(") {
                    cursor_back.backward_char ();
                }
                tab_data.buffer.place_cursor (cursor_back);
                tab_data.buffer.end_user_action ();
                return true;
            }

            schedule_token_suggestions (tab_data);
            return false;
        });

        tab_data.view.add_controller (key_ctrl);
    }

    private string? get_closing_pair (string ch) {
        switch (ch) {
            case "(": return ");";
            case "[": return "]";
            case "{": return "}";
            case "\"": return "\"";
            case "'": return "'";
            case "`": return "`";
            default: return null;
        }
    }

    private bool is_closing_char (string ch) {
        return ch == ")" || ch == "]" || ch == "}" || ch == "\"" || ch == "'" || ch == "`";
    }

    private bool try_remove_empty_pair (EditorTabData tab_data) {
        Gtk.TextIter iter;
        tab_data.buffer.get_iter_at_mark (out iter, tab_data.buffer.get_insert ());

        Gtk.TextIter prev_iter = iter;
        Gtk.TextIter next_iter = iter;
        if (!prev_iter.backward_char () || !next_iter.forward_char ()) {
            return false;
        }

        string left = tab_data.buffer.get_text (prev_iter, iter, false);
        string right = tab_data.buffer.get_text (iter, next_iter, false);
        if (get_closing_pair (left) == right) {
            tab_data.buffer.begin_user_action ();
            tab_data.buffer.delete (ref prev_iter, ref next_iter);
            tab_data.buffer.end_user_action ();
            return true;
        }
        return false;
    }

    private bool try_expand_pair_newline (EditorTabData tab_data) {
        Gtk.TextIter iter;
        tab_data.buffer.get_iter_at_mark (out iter, tab_data.buffer.get_insert ());

        Gtk.TextIter prev_iter = iter;
        Gtk.TextIter next_iter = iter;
        if (!prev_iter.backward_char () || !next_iter.forward_char ()) {
            return false;
        }

        string left = tab_data.buffer.get_text (prev_iter, iter, false);
        string right = tab_data.buffer.get_text (iter, next_iter, false);

        if ((left == "{" && right == "}") || (left == "(" && right == ")")) {
            int line_num = iter.get_line ();
            Gtk.TextIter line_start;
            tab_data.buffer.get_iter_at_line (out line_start, line_num);
            string line_prefix = tab_data.buffer.get_text (line_start, iter, false);

            var indent_sb = new StringBuilder ();
            for (int i = 0; i < line_prefix.length; i++) {
                char c = line_prefix[i];
                if (c == ' ' || c == '\t') {
                    indent_sb.append_c (c);
                } else {
                    break;
                }
            }
            string base_indent = indent_sb.str;
            string inner_indent = base_indent + "    ";

            string insert_block = "\n" + inner_indent + "\n" + base_indent;
            int start_off = iter.get_offset ();
            int inner_chars = 1 + inner_indent.char_count ();

            tab_data.buffer.begin_user_action ();
            tab_data.buffer.insert (ref iter, insert_block, -1);
            Gtk.TextIter target_iter;
            tab_data.buffer.get_iter_at_offset (out target_iter, start_off + inner_chars);
            tab_data.buffer.place_cursor (target_iter);
            tab_data.buffer.end_user_action ();
            return true;
        }

        return false;
    }

    private bool try_expand_snippet (EditorTabData tab_data) {
        Gtk.TextIter iter;
        tab_data.buffer.get_iter_at_mark (out iter, tab_data.buffer.get_insert ());

        Gtk.TextIter word_start = iter;
        while (word_start.backward_char ()) {
            Gtk.TextIter check = word_start;
            check.forward_char ();
            string s = tab_data.buffer.get_text (word_start, check, false);
            if (s.length != 1) {
                word_start.forward_char ();
                break;
            }
            char c = s[0];
            bool is_ident = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                            (c >= '0' && c <= '9') || c == '_';
            if (!is_ident) {
                word_start.forward_char ();
                break;
            }
        }

        string trigger = tab_data.buffer.get_text (word_start, iter, false).strip ();
        if (trigger == "") {
            return false;
        }

        string ext = get_active_ext ();
        string? snippet = lookup_snippet (ext, trigger);
        if (snippet == null) {
            return false;
        }

        string base_indent = get_line_leading_indent (tab_data.buffer, word_start);
        string expanded = snippet.replace ("\n", "\n" + base_indent);

        int cursor_byte_rel = expanded.index_of ("$0");
        string final_text = expanded.replace ("$0", "");
        int start_off = word_start.get_offset ();
        int cursor_char_rel = (cursor_byte_rel >= 0)
            ? expanded.substring (0, cursor_byte_rel).char_count ()
            : final_text.char_count ();

        tab_data.buffer.begin_user_action ();
        tab_data.buffer.delete (ref word_start, ref iter);
        Gtk.TextIter ins_iter;
        tab_data.buffer.get_iter_at_offset (out ins_iter, start_off);
        tab_data.buffer.insert (ref ins_iter, final_text, -1);

        Gtk.TextIter cursor_iter;
        tab_data.buffer.get_iter_at_offset (out cursor_iter, start_off + cursor_char_rel);
        tab_data.buffer.place_cursor (cursor_iter);
        tab_data.buffer.end_user_action ();
        return true;
    }

    private string? lookup_snippet (string ext, string trigger) {
        if (trigger == "if") {
            return (ext == "py") ? "if $0:\n    pass" : "if ($0) {\n    \n}";
        }
        if (trigger == "for") {
            if (ext == "py") return "for i in range($0):\n    pass";
            if (ext == "rs") return "for i in 0..$0 {\n    \n}";
            return "for (int i = 0; i < $0; i++) {\n    \n}";
        }
        if (trigger == "while") {
            return (ext == "py") ? "while $0:\n    pass" : "while ($0) {\n    \n}";
        }
        if (ext == "c") {
            if (trigger == "main") return "int main(void) {\n    $0\n    return 0;\n}";
            if (trigger == "inc") return "#include <$0.h>";
            if (trigger == "pf") return "printf(\"$0\\n\");";
        } else if (ext == "java") {
            if (trigger == "psvm") return "public static void main(String[] args) {\n    $0\n}";
            if (trigger == "sout") return "System.out.println($0);";
        } else if (ext == "py") {
            if (trigger == "fn") return "def $0():\n    pass";
            if (trigger == "main") return "if __name__ == \"__main__\":\n    $0";
        } else if (ext == "js") {
            if (trigger == "fn") return "function $0() {\n    \n}";
            if (trigger == "cl") return "console.log($0);";
        } else if (ext == "rs") {
            if (trigger == "main") return "fn main() {\n    $0\n}";
            if (trigger == "pl") return "println!(\"$0\");";
        } else if (ext == "html" || ext == "htm") {
            if (trigger == "html5") {
                return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n    <meta charset=\"UTF-8\">\n    <title>$0</title>\n</head>\n<body>\n    \n</body>\n</html>";
            }
        }
        return null;
    }

    /* =========================================================================
     * 8. File Manager & File/Session/Command Persistence
     * ========================================================================= */

    private void sync_file_manager_dir_from_active_tab () {
        string prev_dir = current_fm_dir;
        var data = get_current_tab_data ();
        if (data != null && data.file != null) {
            string? parent = data.file.get_parent ()?.get_path ();
            if (parent != null && parent != "" && FileUtils.test (parent, FileTest.IS_DIR)) {
                current_fm_dir = parent;
            }
        }
        refresh_file_manager (prev_dir != current_fm_dir);
    }

    private void refresh_file_manager (bool force = true) {
        if (fm_list_box == null || fm_dir_label == null) {
            return;
        }

        if (!FileUtils.test (current_fm_dir, FileTest.IS_DIR)) {
            current_fm_dir = Environment.get_home_dir () ?? Environment.get_tmp_dir ();
        }

        if (!force && last_fm_rendered_dir == current_fm_dir && fm_list_box.get_first_child () != null) {
            return;
        }

        string home = Environment.get_home_dir () ?? "";
        string display_dir = (home != "" && current_fm_dir.has_prefix (home))
            ? ("~" + current_fm_dir.substring (home.length))
            : current_fm_dir;
        if (display_dir == "") {
            display_dir = Path.DIR_SEPARATOR_S;
        }
        fm_dir_label.set_label (display_dir);
        fm_dir_label.set_tooltip_text (current_fm_dir);

        var child = fm_list_box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            fm_list_box.remove (child);
            child = next;
        }

        var dirs = new GenericArray<string> ();
        var files = new GenericArray<string> ();

        try {
            var dir = Dir.open (current_fm_dir, 0);
            string? entry_name = null;
            while ((entry_name = dir.read_name ()) != null) {
                string full_path = Path.build_filename (current_fm_dir, entry_name);
                if (FileUtils.test (full_path, FileTest.IS_DIR)) {
                    dirs.add (entry_name);
                } else {
                    files.add (entry_name);
                }
            }
        } catch (Error e) {
            append_status ("File manager read error: %s".printf (e.message));
        }

        dirs.sort ((a, b) => strcmp (a.down (), b.down ()));
        files.sort ((a, b) => strcmp (a.down (), b.down ()));

        for (int i = 0; i < dirs.length; i++) {
            string name = dirs[i];
            fm_list_box.append (create_fm_row (name, Path.build_filename (current_fm_dir, name), true));
        }

        for (int i = 0; i < files.length; i++) {
            string name = files[i];
            fm_list_box.append (create_fm_row (name, Path.build_filename (current_fm_dir, name), false));
        }

        last_fm_rendered_dir = current_fm_dir;
    }

    private Gtk.ListBoxRow create_fm_row (string name, string full_path, bool is_dir) {
        var row = new Gtk.ListBoxRow ();
        var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        hbox.set_margin_top (4);
        hbox.set_margin_bottom (4);
        hbox.set_margin_start (6);
        hbox.set_margin_end (4);

        var icon = new Gtk.Image.from_icon_name (
            is_dir ? "folder-symbolic" : "text-x-generic-symbolic"
        );
        var label = new Gtk.Label (name);
        label.set_xalign (0.0f);
        label.set_hexpand (true);
        label.set_ellipsize (Pango.EllipsizeMode.END);
        if (is_dir) {
            label.add_css_class ("heading");
        }

        var del_btn = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        del_btn.add_css_class ("flat");
        del_btn.set_tooltip_text ("Delete %s".printf (name));
        del_btn.clicked.connect (() => confirm_delete_fm_entry (name, full_path, is_dir));

        hbox.append (icon);
        hbox.append (label);
        hbox.append (del_btn);
        row.set_child (hbox);

        row.set_data<string> ("fm-path", full_path);
        row.set_data<bool> ("fm-is-dir", is_dir);
        return row;
    }

    private void delete_file_recursive (GLib.File target) throws Error {
        var file_type = target.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        if (file_type == FileType.DIRECTORY) {
            var enumerator = target.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                null
            );
            FileInfo? info;
            while ((info = enumerator.next_file (null)) != null) {
                delete_file_recursive (target.get_child (info.get_name ()));
            }
        }
        target.delete (null);
    }

    private void close_tabs_for_deleted_path (string deleted_path, bool is_dir) {
        string dir_prefix = (deleted_path.has_suffix ("/") || deleted_path.has_suffix ("\\"))
            ? deleted_path
            : (deleted_path + Path.DIR_SEPARATOR_S);
        for (int i = tab_view.get_n_pages () - 1; i >= 0; i--) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data != null && data.file != null && page != null) {
                string? p = data.file.get_path ();
                if (p != null && (p == deleted_path || (is_dir && p.has_prefix (dir_prefix)))) {
                    data.dirty = false;
                    data.needs_compile = false;
                    detach_token_popover_if_parent (data.view);
                    tab_view.close_page (page);
                }
            }
        }
    }

    private void confirm_delete_fm_entry (string name, string full_path, bool is_dir) {
        var dialog = new Adw.AlertDialog (
            "Delete %s?".printf (is_dir ? "Folder" : "File"),
            "Remove \"%s\" from disk? This cannot be undone.".printf (name)
        );
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("delete", "Delete");
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.set_close_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp != "delete") {
                return;
            }
            try {
                delete_file_recursive (GLib.File.new_for_path (full_path));
                close_tabs_for_deleted_path (full_path, is_dir);
                append_status ("Deleted %s".printf (full_path));
                refresh_file_manager (true);
                schedule_save_session ();
            } catch (Error e) {
                append_status ("Delete error: %s".printf (e.message));
                show_status_dialog ("Delete Error", e.message);
            }
        });

        dialog.present (this);
    }

    private void create_file_in_current_fm_dir () {
        string target_path = Path.build_filename (current_fm_dir, "untitled.txt");
        var f = GLib.File.new_for_path (target_path);
        int counter = 1;
        while (f.query_exists ()) {
            target_path = Path.build_filename (current_fm_dir, "untitled_%d.txt".printf (counter));
            f = GLib.File.new_for_path (target_path);
            counter++;
        }

        string basename = Path.get_basename (target_path);
        var fmt = find_format_for_path (target_path);
        string starter = build_starter_content (fmt, basename);
        if (!write_file_contents (f, starter)) {
            return;
        }

        create_new_tab (f, basename, starter);
        refresh_file_manager (true);
        schedule_save_session ();
        append_status ("Created %s".printf (target_path));
    }

    private LanguageFormat find_format_for_path (string path) {
        string ext = get_extension (Path.get_basename (path)).down ();
        foreach (var fmt in LANG_FORMATS) {
            if (fmt.ext != "" && fmt.ext == ext) {
                return fmt;
            }
        }
        return LANG_FORMATS[LANG_FORMATS.length - 1];
    }

    private bool write_file_contents (GLib.File file, string content) {
        try {
            string? path = file.get_path ();
            if (path != null && path != "") {
                string? parent = Path.get_dirname (path);
                if (parent != null && parent != "") {
                    DirUtils.create_with_parents (parent, 0755);
                }
            }
            file.replace_contents (content.data, null, false, FileCreateFlags.NONE, null, null);
            return true;
        } catch (Error e) {
            warning ("File write failed: %s", e.message);
            return false;
        }
    }

    private bool recreate_missing_file (GLib.File file, string path) {
        var fmt = find_format_for_path (path);
        string starter = build_starter_content (fmt, Path.get_basename (path));
        if (!write_file_contents (file, starter)) {
            return false;
        }
        append_status ("Recreated missing file: %s".printf (path));
        return true;
    }

    private void save_session_now () {
        if (restoring_session) {
            return;
        }

        var sb = new StringBuilder ();
        var selected_page = tab_view.get_selected_page ();
        int active_index = 0;
        int saved_count = 0;

        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? page;
            var data = get_tab_data_at (i, out page);
            if (data != null && data.file != null) {
                string? path = data.file.get_path ();
                if (path != null && path != "") {
                    if (page == selected_page) {
                        active_index = saved_count;
                    }
                    sb.append_printf ("file=%s\n", path);
                    saved_count++;
                }
            }
        }

        sb.append_printf ("active=%d\n", active_index);
        if (last_session_snapshot != null && last_session_snapshot == sb.str) {
            return;
        }

        try {
            DirUtils.create_with_parents (Path.get_dirname (session_path), 0755);
            FileUtils.set_contents (session_path, sb.str);
            last_session_snapshot = sb.str;
        } catch (Error e) {
            warning ("Failed to save session: %s", e.message);
        }
    }

    private void restore_session () {
        restoring_session = true;
        int active_index = 0;
        int opened_count = 0;

        try {
            if (GLib.File.new_for_path (session_path).query_exists ()) {
                string content;
                FileUtils.get_contents (session_path, out content);

                foreach (string raw_line in content.split ("\n")) {
                    string line = raw_line.strip ();
                    if (line == "" || line.has_prefix ("#")) {
                        continue;
                    }
                    if (line.has_prefix ("active=")) {
                        active_index = int.parse (line.substring ("active=".length).strip ());
                    } else if (line.has_prefix ("file=")) {
                        string path = line.substring ("file=".length).strip ();
                        if (path == "") {
                            continue;
                        }
                        var f = GLib.File.new_for_path (path);
                        if (!f.query_exists () && !recreate_missing_file (f, path)) {
                            continue;
                        }
                        open_file_in_tab (f);
                        opened_count++;
                    }
                }
            }
        } catch (Error e) {
            warning ("Failed to restore session: %s", e.message);
        } finally {
            restoring_session = false;
        }

        if (opened_count == 0) {
            create_new_tab (null, "Untitled", "");
        } else {
            int clamped = active_index.clamp (0, tab_view.get_n_pages () - 1);
            tab_view.set_selected_page (tab_view.get_nth_page (clamped));
            refresh_active_tab_state ();
            append_status ("Restored %d session file(s).".printf (opened_count));
        }

        sync_all_tab_glows ();
    }

    private string get_copyright_holder () {
        string? env_user = Environment.get_variable ("USER");
        if (env_user != null && env_user.strip () != "") {
            return env_user.strip ();
        }

        string? user_name = Environment.get_user_name ();
        if (user_name != null && user_name.strip () != "") {
            return user_name.strip ();
        }

        string? real_name = Environment.get_real_name ();
        if (real_name != null) {
            string trimmed = real_name.strip ();
            if (trimmed != "" && trimmed.down () != "unknown") {
                return trimmed;
            }
        }

        return "User";
    }

    private void set_cmd (string section, string action, string cmd) {
        var sec = build_cmds.lookup (section);
        if (sec == null) {
            sec = new HashTable<string, string> (str_hash, str_equal);
            build_cmds.insert (section, sec);
        }
        sec.insert (action, cmd);
    }

    private string? get_cmd (string section, string action) {
        var sec = build_cmds.lookup (section);
        return sec != null ? sec.lookup (action) : null;
    }

    private void load_default_commands () {
#if HAVE_VTE
        set_cmd ("global", "make", "make");
        set_cmd ("c", "compile", "gcc -O2 -Wall -Wextra \"%f\" -o \"%e\"");
        set_cmd ("c", "run", "gcc -O2 -Wall -Wextra \"%f\" -o \"%e\" && ./\"%e\"");
        set_cmd ("java", "compile", "javac \"%f\"");
        set_cmd ("java", "run", "javac \"%f\" && java \"%e\"");
        set_cmd ("js", "compile", "node --check \"%f\"");
        set_cmd ("js", "run", "node \"%f\"");
        set_cmd ("py", "compile", "python3 -m py_compile \"%f\"");
        set_cmd ("py", "run", "python3 \"%f\"");
        set_cmd ("rs", "compile", "rustc -O \"%f\" -o \"%e\"");
        set_cmd ("rs", "run", "rustc -O \"%f\" -o \"%e\" && ./\"%e\"");
        set_cmd ("html", "compile", "echo \"HTML has no compile step.\"");
        set_cmd ("html", "run", "xdg-open \"%f\" >/dev/null 2>&1 &");
        set_cmd ("htm", "compile", "echo \"HTML has no compile step.\"");
        set_cmd ("htm", "run", "xdg-open \"%f\" >/dev/null 2>&1 &");
        set_cmd ("css", "compile", "echo \"CSS has no compile step.\"");
        set_cmd ("css", "run", "echo \"Link %f in an HTML file to preview.\"");
#else
        set_cmd ("global", "make", "mingw32-make");
        set_cmd ("c", "compile", "gcc -O2 -Wall -Wextra \"%f\" -o \"%e.exe\"");
        set_cmd ("c", "run", "gcc -O2 -Wall -Wextra \"%f\" -o \"%e.exe\" && \"%e.exe\"");
        set_cmd ("java", "compile", "javac \"%f\"");
        set_cmd ("java", "run", "javac \"%f\" && java \"%e\"");
        set_cmd ("js", "compile", "node --check \"%f\"");
        set_cmd ("js", "run", "node \"%f\"");
        set_cmd ("py", "compile", "python -m py_compile \"%f\"");
        set_cmd ("py", "run", "python \"%f\"");
        set_cmd ("rs", "compile", "rustc -O \"%f\" -o \"%e.exe\"");
        set_cmd ("rs", "run", "rustc -O \"%f\" -o \"%e.exe\" && \"%e.exe\"");
        set_cmd ("html", "compile", "echo HTML has no compile step.");
        set_cmd ("html", "run", "start \"\" \"%f\"");
        set_cmd ("htm", "compile", "echo HTML has no compile step.");
        set_cmd ("htm", "run", "start \"\" \"%f\"");
        set_cmd ("css", "compile", "echo CSS has no compile step.");
        set_cmd ("css", "run", "echo Link %f in an HTML file to preview.");
#endif
    }

    private void load_user_commands () {
        if (!GLib.File.new_for_path (config_path).query_exists ()) {
            save_user_commands_now ();
            return;
        }

        try {
            string content;
            FileUtils.get_contents (config_path, out content);

            string current_section = "global";
            foreach (string raw_line in content.split ("\n")) {
                string line = raw_line.strip ();
                if (line == "" || line.has_prefix ("#") || line.has_prefix (";")) {
                    continue;
                }
                if (line.has_prefix ("[") && line.has_suffix ("]")) {
                    current_section = line.substring (1, line.length - 2).strip ().down ();
                    continue;
                }
                int eq = line.index_of_char ('=');
                if (eq > 0) {
                    set_cmd (
                        current_section,
                        line.substring (0, eq).strip ().down (),
                        line.substring (eq + 1).strip ()
                    );
                }
            }
        } catch (Error e) {
            warning ("Failed to read config: %s", e.message);
        }
    }

    private void save_user_commands_now () {
        var sb = new StringBuilder ();
        sb.append ("# RookieIDE Build Commands\n");
        sb.append ("# Placeholders: %%f = filename, %%e = name without ext, %%d = directory\n\n");

        var seen = new GenericSet<string> (str_hash, str_equal);
        foreach (string sec_name in ORDERED_SECTIONS) {
            if (build_cmds.contains (sec_name)) {
                append_section_to_builder (sb, sec_name);
                seen.add (sec_name);
            }
        }

        build_cmds.foreach ((k, _v) => {
            if (!seen.contains (k)) {
                append_section_to_builder (sb, k);
            }
        });

        if (last_cmds_snapshot != null && last_cmds_snapshot == sb.str) {
            return;
        }

        try {
            DirUtils.create_with_parents (Path.get_dirname (config_path), 0755);
            FileUtils.set_contents (config_path, sb.str);
            last_cmds_snapshot = sb.str;
        } catch (Error e) {
            warning ("Failed to save config: %s", e.message);
        }
    }

    private void append_section_to_builder (StringBuilder sb, string sec_name) {
        var sec = build_cmds.lookup (sec_name);
        if (sec == null) {
            return;
        }
        sb.append_printf ("[%s]\n", sec_name);
        sec.foreach ((k, v) => sb.append_printf ("%s=%s\n", k, v));
        sb.append ("\n");
    }

    private void flush_pending_saves () {
        if (save_session_timeout_id != 0) {
            Source.remove (save_session_timeout_id);
            save_session_timeout_id = 0;
        }
        if (save_cmds_timeout_id != 0) {
            Source.remove (save_cmds_timeout_id);
            save_cmds_timeout_id = 0;
        }
        if (save_profiles_timeout_id != 0) {
            Source.remove (save_profiles_timeout_id);
            save_profiles_timeout_id = 0;
        }
        if (save_labels_timeout_id != 0) {
            Source.remove (save_labels_timeout_id);
            save_labels_timeout_id = 0;
        }
        save_session_now ();
        save_user_commands_now ();
        save_user_profiles_now ();
        save_user_line_labels_now ();
    }

    private void schedule_save_session () {
        if (restoring_session || closing_tab) {
            return;
        }
        if (save_session_timeout_id != 0) {
            Source.remove (save_session_timeout_id);
        }
        save_session_timeout_id = Timeout.add (150, () => {
            save_session_timeout_id = 0;
            save_session_now ();
            return Source.REMOVE;
        });
    }

    private void schedule_save_commands () {
        if (save_cmds_timeout_id != 0) {
            Source.remove (save_cmds_timeout_id);
        }
        save_cmds_timeout_id = Timeout.add (250, () => {
            save_cmds_timeout_id = 0;
            save_user_commands_now ();
            return Source.REMOVE;
        });
    }

    private void on_open_clicked () {
        var dialog = new Gtk.FileDialog ();
        dialog.open.begin (this, null, (_obj, res) => {
            try {
                GLib.File? file = dialog.open.end (res);
                if (file != null) {
                    open_file_in_tab (file);
                    sync_file_manager_dir_from_active_tab ();
                    schedule_save_session ();
                    append_status ("Opened %s".printf (file.get_path () ?? ""));
                }
            } catch (Error e) {
                if (!(e is Gtk.DialogError.DISMISSED)) {
                    append_status ("Open error: %s".printf (e.message));
                    show_status_dialog ("Open Error", e.message);
                }
            }
        });
    }

    private void open_file_in_tab (GLib.File file) {
        int n = tab_view.get_n_pages ();
        for (int i = 0; i < n; i++) {
            Adw.TabPage? existing_page;
            var existing_data = get_tab_data_at (i, out existing_page);
            if (existing_data != null && existing_data.file != null && existing_data.file.equal (file)) {
                tab_view.set_selected_page (existing_page);
                if (!restoring_session) {
                    refresh_active_tab_state ();
                }
                return;
            }
        }

        try {
            uint8[] contents;
            file.load_contents (null, out contents, null);
            string basename = file.get_basename () ?? "Untitled";
            create_new_tab (file, basename, ((string) contents).make_valid (-1));
            if (!restoring_session) {
                refresh_active_tab_state ();
            }
        } catch (Error e) {
            append_status ("Read error: %s".printf (e.message));
            show_status_dialog ("Read Error", e.message);
        }
    }

    private bool save_current_tab (bool notify_saved = false) {
        var page = tab_view.get_selected_page ();
        var data = get_current_tab_data ();
        if (page == null || data == null) {
            return false;
        }

        if (data.file == null) {
            var dialog = new Gtk.FileDialog ();
            dialog.set_initial_name (page.get_title ().replace ("*", ""));
            dialog.save.begin (this, null, (_obj, res) => {
                try {
                    GLib.File? chosen = dialog.save.end (res);
                    if (chosen != null) {
                        data.file = chosen;
                        apply_saved_labels_to_tab (data, page);
                        write_tab_to_disk (page, data, notify_saved);
                        sync_file_manager_dir_from_active_tab ();
                        schedule_save_session ();
                    }
                } catch (Error e) {
                    if (!(e is Gtk.DialogError.DISMISSED)) {
                        append_status ("Save error: %s".printf (e.message));
                        show_status_dialog ("Save Error", e.message);
                    }
                }
            });
            return false;
        }

        return write_tab_to_disk (page, data, notify_saved);
    }

    private bool write_tab_to_disk (Adw.TabPage page, EditorTabData data, bool notify_saved = false) {
        if (data.file == null) {
            return false;
        }

        Gtk.TextIter start_iter, end_iter;
        data.buffer.get_bounds (out start_iter, out end_iter);
        string text = data.buffer.get_text (start_iter, end_iter, true);

        if (!write_file_contents (data.file, text)) {
            append_status ("Save failed for %s".printf (data.file.get_basename () ?? "file"));
            show_status_dialog ("Save Failed", "Could not write file to disk.");
            return false;
        }

        data.dirty = false;
        string basename = data.file.get_basename () ?? "Untitled";
        string full_path = data.file.get_path () ?? basename;
        data.buffer.set_language (lang_mgr.guess_language (basename, null));

        syncing_title = true;
        page.set_title (basename);
        syncing_title = false;

        sync_tab_labels_to_store (data, page);
        schedule_save_line_labels ();
        refresh_active_tab_state ();
        refresh_file_manager (true);
        sync_all_tab_glows ();
        schedule_save_session ();

        string saved_msg = "saved successfully (%s)".printf (full_path);
        append_status (saved_msg);

        if (notify_saved) {
            select_bottom_tab ("status");
            show_status_dialog ("Saved", "saved successfully\n\n%s".printf (full_path));
        }
        return true;
    }

    /* =========================================================================
     * 9. Build Runner, Compiler Logs & VTE Terminal
     * ========================================================================= */

    private void select_bottom_tab (string name) {
        if (bottom_stack == null) {
            return;
        }
#if !HAVE_VTE
        if (name == "terminal") {
            name = "compiler";
        }
#endif
        bottom_stack.set_visible_child_name (name);

        syncing_bottom_tabs = true;
#if HAVE_VTE
        Gtk.ToggleButton?[] buttons = { status_tab_btn, compiler_tab_btn, terminal_tab_btn };
        string?[] names = { "status", "compiler", "terminal" };
#else
        Gtk.ToggleButton?[] buttons = { status_tab_btn, compiler_tab_btn };
        string?[] names = { "status", "compiler" };
#endif

        for (int i = 0; i < buttons.length; i++) {
            bool active = (name == names[i]);
            buttons[i].set_active (active);
            if (active) {
                buttons[i].add_css_class ("bottom-tab-active");
            } else {
                buttons[i].remove_css_class ("bottom-tab-active");
            }
        }
        syncing_bottom_tabs = false;
    }

    private void ensure_compiler_error_tag () {
        if (compiler_buffer == null || compiler_error_tag != null) {
            return;
        }
        var fg = Gdk.RGBA ();
        fg.parse ("#ff6b72");
        var bg = Gdk.RGBA ();
        bg.parse ("#3d1216");
        compiler_error_tag = compiler_buffer.create_tag (
            "compile-error",
            "foreground-rgba", fg,
            "background-rgba", bg,
            "weight", Pango.Weight.BOLD
        );
    }

    private bool line_looks_like_error (string line) {
        string lower = line.down ();
        return lower.contains ("error:") ||
               lower.contains ("error [") ||
               lower.contains ("fatal error") ||
               lower.contains ("exception") ||
               lower.contains ("cannot find symbol") ||
               lower.contains ("undefined reference") ||
               lower.contains ("syntaxerror") ||
               lower.contains ("failed (exit code") ||
               lower.has_prefix ("error:") ||
               lower.has_prefix ("failed");
    }

    private void append_log_line (Gtk.TextBuffer? buf, Gtk.TextView? view, string text, bool highlight_error = false) {
        if (buf == null || view == null) {
            return;
        }
        Gtk.TextIter start_iter, end_iter;
        buf.get_end_iter (out end_iter);
        int start_offset = end_iter.get_offset ();

        string line = text.has_suffix ("\n") ? text : (text + "\n");
        buf.insert (ref end_iter, line, -1);

        if (highlight_error && buf == compiler_buffer) {
            ensure_compiler_error_tag ();
            if (compiler_error_tag != null) {
                buf.get_iter_at_offset (out start_iter, start_offset);
                buf.get_end_iter (out end_iter);
                buf.apply_tag (compiler_error_tag, start_iter, end_iter);
            }
        }

        buf.get_end_iter (out end_iter);
        view.scroll_to_iter (end_iter, 0.0, false, 0.0, 0.0);
    }

    private void clear_log_buffers () {
        if (status_buffer != null) {
            status_buffer.set_text ("");
        }
        if (compiler_buffer != null) {
            compiler_buffer.set_text ("");
        }
    }

    private void append_status (string msg) {
        var now = new DateTime.now_local ();
        append_log_line (status_buffer, status_view, "[%s] %s".printf (now.format ("%H:%M:%S"), msg), false);
    }

    private void append_compiler (string msg, bool force_error = false) {
        foreach (string raw_line in msg.split ("\n")) {
            if (raw_line == "" && msg.strip () == "") {
                continue;
            }
            bool is_err = force_error || line_looks_like_error (raw_line);
            append_log_line (compiler_buffer, compiler_view, raw_line, is_err);
        }
    }

    private string sanitize_output_text (string raw) {
        string valid = raw.make_valid (-1);
        var sb = new StringBuilder ();
        for (int i = 0; i < valid.length; i++) {
            char c = valid[i];
            if ((c >= 0x20 && c != 0x7f) || c == '\n' || c == '\t') {
                sb.append_c (c);
            }
        }
        return sb.str.strip ();
    }

    private void show_status_dialog (string heading, string body) {
        var dialog = new Adw.AlertDialog (heading, sanitize_output_text (body));
        dialog.add_response ("ok", "OK");
        dialog.set_default_response ("ok");
        dialog.set_close_response ("ok");
        dialog.present (this);
    }

    private string get_active_ext () {
        var data = get_current_tab_data ();
        if (data != null && data.file != null) {
            string ext = get_extension (data.file.get_basename () ?? "").down ();
            if (ext != "") {
                return ext;
            }
        }
        return "c";
    }

    private void refresh_inline_command_bar () {
        syncing_entries = true;
        string ext = get_active_ext ();
        active_lang_label.set_label ("Target: ." + ext);
        compile_entry.set_text (get_cmd (ext, "compile") ?? "");
        run_entry.set_text (get_cmd (ext, "run") ?? "");
#if HAVE_VTE
        make_entry.set_text (get_cmd ("global", "make") ?? "make");
#else
        make_entry.set_text (get_cmd ("global", "make") ?? "mingw32-make");
#endif
        syncing_entries = false;
    }

    private void apply_inline_entries () {
        if (syncing_entries) {
            return;
        }
        string ext = get_active_ext ();
        set_cmd (ext, "compile", compile_entry.get_text ());
        set_cmd (ext, "run", run_entry.get_text ());

#if HAVE_VTE
        string default_make = "make";
#else
        string default_make = "mingw32-make";
#endif
        string make_val = make_entry.get_text ().strip ();
        set_cmd ("global", "make", make_val != "" ? make_val : default_make);

        schedule_save_commands ();
    }

#if HAVE_VTE
    private void start_shell () {
        string home = Environment.get_home_dir () ?? "/";
        string[] argv = { "/bin/bash" };

        terminal.spawn_async (
            Vte.PtyFlags.DEFAULT,
            home,
            argv,
            null,
            SpawnFlags.SEARCH_PATH,
            null,
            -1,
            null,
            null
        );
    }
#endif

    private void run_compiler_subprocess (string action_label, string dir, string target_filename, string command_line) {
#if HAVE_VTE
        string[] argv = { "/bin/sh", "-c", command_line };
#else
        string[] argv = { "cmd.exe", "/C", command_line };
#endif
        select_bottom_tab ("compiler");
        append_compiler ("--- %s (%s) ---".printf (action_label, dir), false);
        append_compiler ("$ %s".printf (command_line), false);
        clear_error_highlights_all_tabs ();

        try {
            var launcher = new GLib.SubprocessLauncher (
                GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_PIPE
            );
            launcher.set_cwd (dir);
            var proc = launcher.spawnv (argv);

            proc.communicate_utf8_async.begin (null, null, (_obj, res) => {
                try {
                    string stdout_buf;
                    string stderr_buf;
                    proc.communicate_utf8_async.end (res, out stdout_buf, out stderr_buf);

                    bool ok = proc.get_successful ();
                    int code = proc.get_exit_status ();

                    string out_clean = sanitize_output_text (stdout_buf);
                    string err_clean = sanitize_output_text (stderr_buf);

                    if (out_clean != "") {
                        append_compiler (out_clean, false);
                    }
                    if (err_clean != "") {
                        append_compiler (err_clean, !ok);
                    }

                    if (!ok || err_clean != "") {
                        highlight_error_lines_from_output (err_clean + "\n" + out_clean);
                    }

                    string details = (err_clean != "") ? err_clean : out_clean;
                    if (details.length > 400) {
                        details = details.substring (0, 400) + "...";
                    }

                    if (ok) {
                        clear_uncompiled_glow_for_target (dir, target_filename);
                        string heading = (action_label == "Compile")
                            ? "Compiled successfully"
                            : "%s Completed".printf (action_label);
                        string body = (details != "") ? "%s\n\n%s".printf (heading, details) : heading;

                        append_compiler ("[%s] %s\n".printf (action_label, heading), false);
                        append_status ("%s: %s".printf (action_label, heading));
                        show_status_dialog (heading, body);
                    } else {
                        string heading = "%s Failed".printf (action_label);
                        string body = (details != "")
                            ? "%s failed (exit code %d).\n\n%s".printf (action_label, code, details)
                            : "%s failed (exit code %d).".printf (action_label, code);

                        append_compiler ("[%s] Failed (exit code %d)\n".printf (action_label, code), true);
                        append_status ("%s failed (exit code %d)".printf (action_label, code));
                        show_status_dialog (heading, body);
                    }
                } catch (Error e) {
                    string clean_err = sanitize_output_text (e.message);
                    append_compiler ("[%s] Error: %s\n".printf (action_label, clean_err), true);
                    append_status ("%s error: %s".printf (action_label, clean_err));
                    show_status_dialog ("%s Error".printf (action_label), clean_err);
                }
            });
        } catch (Error e) {
            string clean_err = sanitize_output_text (e.message);
            append_compiler ("Launch error: %s\n".printf (clean_err), true);
            append_status ("Launch error: %s".printf (clean_err));
            show_status_dialog ("Launch Error", clean_err);
        }
    }

    private void run_action (string mode) {
        var data = get_current_tab_data ();
        if (data == null) {
            return;
        }

        if (data.file == null) {
            append_status ("Unsaved tab: prompting to save before %s.".printf (mode));
            save_current_tab (false);
            return;
        }

        if (!write_tab_to_disk (tab_view.get_selected_page (), data, false)) {
            return;
        }

        string? dir = data.file.get_parent ()?.get_path ();
        string filename = data.file.get_basename () ?? "";
        if (dir == null) {
            return;
        }

        string ext = get_extension (filename).down ();
        string stem = strip_extension (filename);

#if HAVE_VTE
        string default_make = "make";
#else
        string default_make = "mingw32-make";
#endif
        string? template_cmd = (mode == "make")
            ? (get_cmd ("global", "make") ?? default_make)
            : get_cmd (ext, mode);

        if (template_cmd == null || template_cmd.strip () == "") {
            string msg = "No %s command configured for .%s.".printf (mode, ext);
            append_status (msg);
            show_status_dialog ("Command Not Configured", msg);
            return;
        }

        string expanded = template_cmd
            .replace ("%f", filename)
            .replace ("%e", stem)
            .replace ("%d", dir);

#if HAVE_VTE
        if (mode == "compile" || mode == "make") {
            string label = (mode == "compile") ? "Compile" : "Make";
            run_compiler_subprocess (label, dir, filename, expanded);
        } else {
            select_bottom_tab ("terminal");
            append_status ("Running %s in %s".printf (filename, dir));
            terminal.feed_child (("cd %s && %s\n".printf (shell_escape (dir), expanded)).data);
        }
#else
        string label = (mode == "compile") ? "Compile" : ((mode == "make") ? "Make" : "Run");
        run_compiler_subprocess (label, dir, filename, expanded);
#endif
    }

    private string get_extension (string filename) {
        int dot = filename.last_index_of_char ('.');
        if (dot <= 0 || dot == filename.length - 1) {
            return "";
        }
        return filename.substring (dot + 1);
    }

    private string strip_extension (string filename) {
        int dot = filename.last_index_of_char ('.');
        return dot <= 0 ? filename : filename.substring (0, dot);
    }

#if HAVE_VTE
    private string shell_escape (string s) {
        return "'" + s.replace ("'", "'\\''") + "'";
    }
#endif

    /* =========================================================================
     * 10. UI Layout, New File Dialog & Shortcuts
     * ========================================================================= */

    private int get_effective_width () {
        int alloc_w = main_paned != null ? main_paned.get_width () : 0;
        if (alloc_w > 0) {
            return alloc_w;
        }
        int win_w = this.get_width ();
        return win_w > 0 ? win_w : this.default_width;
    }

    private int get_effective_height () {
        int alloc_h = editor_paned != null ? editor_paned.get_height () : 0;
        if (alloc_h > 0) {
            return alloc_h;
        }
        int win_h = this.get_height ();
        return win_h > 0 ? win_h : this.default_height;
    }

    private void sync_sidebar_split_ratio (bool force = false) {
        if (main_paned == null || file_sidebar == null || !file_sidebar.get_visible ()) {
            return;
        }
        if (user_adjusted_sidebar_split && !force) {
            return;
        }

        int w = get_effective_width ();
        int target_pos = ((int) (w * 0.20)).clamp (160, int.max (200, w - 320));

        syncing_sidebar_position = true;
        main_paned.set_position (target_pos);
        syncing_sidebar_position = false;
    }

    private void apply_startup_splits (bool force_sidebar = false) {
        if (file_sidebar != null && file_sidebar.get_visible ()) {
            sync_sidebar_split_ratio (force_sidebar);
        }
        if (!initial_layout_applied && editor_paned != null) {
            int h = get_effective_height ();
            editor_paned.set_position (((int) (h * 0.78)).clamp (260, int.max (320, h - 130)));
            initial_layout_applied = true;
        }
    }

    private Gtk.Box build_log_page (Gtk.TextBuffer buf, out Gtk.TextView out_view) {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.set_vexpand (true);
        box.set_hexpand (true);

        var view = new Gtk.TextView.with_buffer (buf);
        view.set_editable (false);
        view.set_cursor_visible (false);
        view.set_monospace (true);
        view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        view.set_vexpand (true);
        view.set_hexpand (true);

        var scroll = new Gtk.ScrolledWindow ();
        scroll.set_vexpand (true);
        scroll.set_hexpand (true);
        scroll.set_child (view);
        box.append (scroll);

        out_view = view;
        return box;
    }

    private Gtk.Box build_file_manager_sidebar () {
        var sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        sidebar.add_css_class ("fm-sidebar");
        sidebar.set_size_request (160, -1);
        sidebar.set_vexpand (true);

        var top_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        top_bar.set_margin_top (6);
        top_bar.set_margin_bottom (6);
        top_bar.set_margin_start (8);
        top_bar.set_margin_end (6);

        var fm_title = new Gtk.Label ("PROJECT FILES");
        fm_title.add_css_class ("heading");
        fm_title.set_xalign (0.0f);
        fm_title.set_hexpand (true);

        var up_btn = new Gtk.Button.from_icon_name ("go-up-symbolic");
        up_btn.add_css_class ("flat");
        up_btn.set_tooltip_text ("Parent Directory");
        up_btn.clicked.connect (() => {
            string parent = Path.get_dirname (current_fm_dir);
            if (parent != "" && parent != current_fm_dir) {
                current_fm_dir = parent;
                refresh_file_manager (true);
            }
        });

        var new_fm_btn = new Gtk.Button.from_icon_name ("document-new-symbolic");
        new_fm_btn.add_css_class ("flat");
        new_fm_btn.set_tooltip_text ("New File in Current Directory");
        new_fm_btn.clicked.connect (() => create_file_in_current_fm_dir ());

        var refresh_btn = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
        refresh_btn.add_css_class ("flat");
        refresh_btn.set_tooltip_text ("Refresh Directory");
        refresh_btn.clicked.connect (() => refresh_file_manager (true));

        top_bar.append (fm_title);
        top_bar.append (up_btn);
        top_bar.append (new_fm_btn);
        top_bar.append (refresh_btn);

        fm_dir_label = new Gtk.Label ("~");
        fm_dir_label.add_css_class ("dim-label");
        fm_dir_label.set_xalign (0.0f);
        fm_dir_label.set_ellipsize (Pango.EllipsizeMode.START);
        fm_dir_label.set_margin_start (8);
        fm_dir_label.set_margin_end (8);
        fm_dir_label.set_margin_bottom (6);

        fm_list_box = new Gtk.ListBox ();
        fm_list_box.set_selection_mode (Gtk.SelectionMode.NONE);
        fm_list_box.row_activated.connect ((row) => {
            string? path = row.get_data<string> ("fm-path");
            bool is_dir = row.get_data<bool> ("fm-is-dir");
            if (path == null || path == "") {
                return;
            }
            if (is_dir) {
                current_fm_dir = path;
                refresh_file_manager (true);
            } else {
                open_file_in_tab (GLib.File.new_for_path (path));
                schedule_save_session ();
            }
        });

        var fm_scroll = new Gtk.ScrolledWindow ();
        fm_scroll.set_vexpand (true);
        fm_scroll.set_hexpand (true);
        fm_scroll.set_child (fm_list_box);

        var sidebar_split = new Gtk.Paned (Gtk.Orientation.VERTICAL);
        sidebar_split.set_vexpand (true);
        sidebar_split.set_hexpand (true);
        sidebar_split.set_start_child (fm_scroll);
        sidebar_split.set_resize_start_child (true);
        sidebar_split.set_shrink_start_child (false);

        var labels_section = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        labels_section.set_size_request (-1, 180);
        labels_section.set_margin_top (6);
        labels_section.set_margin_bottom (6);
        labels_section.set_margin_start (8);
        labels_section.set_margin_end (8);

        var labels_header = new Gtk.Label ("LINE LABELS");
        labels_header.add_css_class ("heading");
        labels_header.set_xalign (0.0f);

        var add_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        line_label_entry = new Gtk.Entry ();
        line_label_entry.set_placeholder_text ("Label name...");
        line_label_entry.set_hexpand (true);
        line_label_entry.activate.connect (() => add_current_line_label ());

        var add_label_btn = new Gtk.Button.with_label ("Add");
        add_label_btn.add_css_class ("suggested-action");
        add_label_btn.clicked.connect (() => add_current_line_label ());

        add_row.append (line_label_entry);
        add_row.append (add_label_btn);

        line_desc_entry = new Gtk.Entry ();
        line_desc_entry.set_placeholder_text ("Description (optional)...");
        line_desc_entry.set_hexpand (true);
        line_desc_entry.activate.connect (() => add_current_line_label ());

        line_labels_list = new Gtk.ListBox ();
        line_labels_list.set_selection_mode (Gtk.SelectionMode.SINGLE);
        line_labels_list.row_activated.connect ((row) => {
            int target_line = row.get_data<int> ("target-line");
            jump_to_line_index (target_line);
        });

        var labels_scroll = new Gtk.ScrolledWindow ();
        labels_scroll.set_vexpand (true);
        labels_scroll.set_hexpand (true);
        labels_scroll.set_child (line_labels_list);

        labels_section.append (labels_header);
        labels_section.append (add_row);
        labels_section.append (line_desc_entry);
        labels_section.append (labels_scroll);

        sidebar_split.set_end_child (labels_section);
        sidebar_split.set_resize_end_child (false);
        sidebar_split.set_shrink_end_child (false);
        sidebar_split.set_position (260);

        sidebar.append (top_bar);
        sidebar.append (fm_dir_label);
        sidebar.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        sidebar.append (sidebar_split);
        return sidebar;
    }

    private Gtk.Entry create_cmd_entry (string placeholder, string action_mode) {
        var entry = new Gtk.Entry ();
        entry.set_placeholder_text (placeholder);
        entry.set_hexpand (true);
        entry.changed.connect (() => apply_inline_entries ());
        entry.activate.connect (() => run_action (action_mode));
        return entry;
    }

    private Gtk.ToggleButton create_bottom_tab_button (string label, string target_name) {
        var btn = new Gtk.ToggleButton.with_label (label);
        btn.add_css_class ("flat");
        btn.add_css_class ("bottom-tab-btn");
        btn.toggled.connect (() => {
            if (!syncing_bottom_tabs) {
                select_bottom_tab (target_name);
            }
        });
        return btn;
    }

    private void build_ui () {
        install_ui_css ();

        var main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        this.set_content (main_box);

        var header = new Adw.HeaderBar ();
        title_widget = new Adw.WindowTitle ("Untitled", "Unsaved buffer");
        header.set_title_widget (title_widget);
        main_box.append (header);

        var left_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        left_box.set_valign (Gtk.Align.CENTER);

        var brand_label = new Gtk.Label ("RookieIDE");
        brand_label.add_css_class ("heading");
        brand_label.set_valign (Gtk.Align.CENTER);

        var file_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        file_box.add_css_class ("linked");

        var new_btn = new Gtk.Button.with_label ("New");
        new_btn.tooltip_text = "New File with Language Format (Ctrl+N)";
        new_btn.clicked.connect (open_new_file_dialog);

        var open_btn = new Gtk.Button.with_label ("Open");
        open_btn.tooltip_text = "Open File in Tab (Ctrl+O)";
        open_btn.clicked.connect (on_open_clicked);

        var save_btn = new Gtk.Button.with_label ("Save");
        save_btn.tooltip_text = "Save Active Tab (Ctrl+S)";
        save_btn.clicked.connect (() => save_current_tab (true));

        file_box.append (new_btn);
        file_box.append (open_btn);
        file_box.append (save_btn);

        search_entry = new Gtk.SearchEntry ();
        search_entry.set_placeholder_text ("Find...");
        search_entry.tooltip_text = "Search in active file (Ctrl+F: Focus, Enter: Next match, Shift+Enter: Previous)";
        search_entry.set_width_chars (16);
        search_entry.set_valign (Gtk.Align.CENTER);
        search_entry.search_changed.connect (() => go_to_search_match (false, false, false));
        search_entry.activate.connect (() => go_to_search_match (false, true, true));
        search_entry.previous_match.connect (() => go_to_search_match (true, true, true));
        search_entry.next_match.connect (() => go_to_search_match (false, true, true));

        left_box.append (brand_label);
        left_box.append (file_box);
        left_box.append (search_entry);
        header.pack_start (left_box);

        var settings_btn = new Gtk.Button.from_icon_name ("emblem-system-symbolic");
        settings_btn.set_tooltip_text ("Themes, Plugins & Profiles (Ctrl+,)");
        settings_btn.clicked.connect (open_theme_profiles_dialog);
        header.pack_end (settings_btn);

        var toggle_bar_btn = new Gtk.ToggleButton.with_label ("Commands");
        toggle_bar_btn.set_tooltip_text ("Customize Compile, Make, and Run commands");
        toggle_bar_btn.toggled.connect (() => cmd_revealer.set_reveal_child (toggle_bar_btn.get_active ()));
        header.pack_end (toggle_bar_btn);

        var build_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        build_box.add_css_class ("linked");

        var compile_btn = new Gtk.Button.with_label ("Compile");
        compile_btn.tooltip_text = "Compile (F8)";
        compile_btn.clicked.connect (() => run_action ("compile"));

        var make_btn = new Gtk.Button.with_label ("Make");
        make_btn.tooltip_text = "Make (F9)";
        make_btn.clicked.connect (() => run_action ("make"));

        var run_btn = new Gtk.Button.from_icon_name ("media-playback-start-symbolic");
        run_btn.tooltip_text = "Run (F5)";
        run_btn.add_css_class ("suggested-action");
        run_btn.clicked.connect (() => run_action ("run"));

        build_box.append (compile_btn);
        build_box.append (make_btn);
        build_box.append (run_btn);
        header.pack_end (build_box);

        cmd_revealer = new Gtk.Revealer ();
        cmd_revealer.set_transition_type (Gtk.RevealerTransitionType.SLIDE_DOWN);
        cmd_revealer.set_reveal_child (false);
        main_box.append (cmd_revealer);

        var bar_frame = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        bar_frame.set_margin_top (8);
        bar_frame.set_margin_bottom (8);
        bar_frame.set_margin_start (12);
        bar_frame.set_margin_end (12);
        cmd_revealer.set_child (bar_frame);

        var top_meta = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        active_lang_label = new Gtk.Label ("Target: .c");
        active_lang_label.add_css_class ("heading");
        active_lang_label.set_halign (Gtk.Align.START);

        var hint_label = new Gtk.Label ("Placeholders: %f (file), %e (name), %d (folder) — saves automatically");
        hint_label.add_css_class ("dim-label");
        hint_label.set_halign (Gtk.Align.END);
        hint_label.set_hexpand (true);

        top_meta.append (active_lang_label);
        top_meta.append (hint_label);
        bar_frame.append (top_meta);

        var entries_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        bar_frame.append (entries_row);

        compile_entry = create_cmd_entry ("Compile command...", "compile");
        make_entry = create_cmd_entry ("Make command...", "make");
        run_entry = create_cmd_entry ("Run command...", "run");

        entries_row.append (new Gtk.Label ("Compile:"));
        entries_row.append (compile_entry);
        entries_row.append (new Gtk.Label ("Make:"));
        entries_row.append (make_entry);
        entries_row.append (new Gtk.Label ("Run:"));
        entries_row.append (run_entry);

        main_paned = new Gtk.Paned (Gtk.Orientation.HORIZONTAL);
        main_paned.set_vexpand (true);
        main_paned.set_hexpand (true);
        main_paned.set_position ((int) (this.default_width * 0.20));
        main_paned.notify["position"].connect (() => {
            if (!syncing_sidebar_position && file_sidebar.get_visible ()) {
                user_adjusted_sidebar_split = true;
            }
        });
        main_box.append (main_paned);

        file_sidebar = build_file_manager_sidebar ();
        main_paned.set_start_child (file_sidebar);
        main_paned.set_resize_start_child (false);
        main_paned.set_shrink_start_child (false);

        editor_paned = new Gtk.Paned (Gtk.Orientation.VERTICAL);
        editor_paned.set_vexpand (true);
        editor_paned.set_hexpand (true);
        editor_paned.set_position ((int) (this.default_height * 0.78));
        main_paned.set_end_child (editor_paned);
        main_paned.set_resize_end_child (true);
        main_paned.set_shrink_end_child (false);

        var editor_area = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        editor_area.set_vexpand (true);
        editor_area.set_hexpand (true);

        tab_view = new Adw.TabView ();
        tab_view.set_vexpand (true);
        tab_view.set_hexpand (true);
        tab_view.create_window.connect (() => {
            var app = this.get_application () as Adw.Application;
            if (app == null) {
                return null;
            }
            var new_win = new RookieIdeWindow (app);
            new_win.present ();
            return new_win.tab_view;
        });
        tab_view.notify["selected-page"].connect (() => {
            hide_token_popover ();
            if (!restoring_session && !closing_tab) {
                refresh_active_tab_state ();
                sync_file_manager_dir_from_active_tab ();
                sync_all_tab_glows ();
                if (search_entry != null && search_entry.get_text () != "") {
                    go_to_search_match (false, false, false);
                } else {
                    set_search_no_match (false);
                }
                schedule_save_session ();
            }
        });
        tab_view.close_page.connect ((page) => {
            var data = page.get_data<EditorTabData> ("tab-data");
            if (data != null && data.dirty) {
                prompt_close_dirty_page (page, data);
                return true;
            }
            finalize_tab_close (page, data);
            return true;
        });

        tab_bar = new Adw.TabBar ();
        tab_bar.set_autohide (false);

        editor_area.append (tab_bar);
        editor_area.append (tab_view);
        editor_paned.set_start_child (editor_area);
        editor_paned.set_resize_start_child (true);
        editor_paned.set_shrink_start_child (false);

        Adw.StyleManager.get_default ().notify["dark"].connect (() => {
            if (get_active_profile ().style_scheme == "auto") {
                apply_active_profile_now ();
            }
        });

        var bottom_dock = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        bottom_dock.set_size_request (-1, 110);
        bottom_dock.set_vexpand (true);
        bottom_dock.set_hexpand (true);

        var top_tabs_bar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        top_tabs_bar.add_css_class ("bottom-tab-strip");
        top_tabs_bar.set_hexpand (true);

        status_tab_btn = create_bottom_tab_button ("Status", "status");
        compiler_tab_btn = create_bottom_tab_button ("Compiler", "compiler");

        top_tabs_bar.append (status_tab_btn);
        top_tabs_bar.append (compiler_tab_btn);

#if HAVE_VTE
        terminal_tab_btn = create_bottom_tab_button ("Terminal (VTE)", "terminal");
        top_tabs_bar.append (terminal_tab_btn);
#endif

        bottom_stack = new Gtk.Stack ();
        bottom_stack.set_vexpand (true);
        bottom_stack.set_hexpand (true);

        status_buffer = new Gtk.TextBuffer (null);
        bottom_stack.add_named (build_log_page (status_buffer, out status_view), "status");

        compiler_buffer = new Gtk.TextBuffer (null);
        ensure_compiler_error_tag ();
        bottom_stack.add_named (build_log_page (compiler_buffer, out compiler_view), "compiler");

#if HAVE_VTE
        terminal = new Vte.Terminal ();
        terminal.set_vexpand (true);
        terminal.set_hexpand (true);
        var term_scroll = new Gtk.ScrolledWindow ();
        term_scroll.set_vexpand (true);
        term_scroll.set_hexpand (true);
        term_scroll.set_child (terminal);
        bottom_stack.add_named (term_scroll, "terminal");
#endif

        bottom_dock.append (top_tabs_bar);
        bottom_dock.append (bottom_stack);
        editor_paned.set_end_child (bottom_dock);
        editor_paned.set_resize_end_child (false);
        editor_paned.set_shrink_end_child (false);

        select_bottom_tab ("status");
    }

    private string build_starter_content (LanguageFormat fmt, string filename) {
        string stem = strip_extension (filename);
        string target_name = (fmt.ext == "java") ? sanitize_java_identifier (stem) : stem;
        return fmt.base_template
            .replace ("%e", target_name)
            .replace ("%f", filename)
            .replace ("%u", get_copyright_holder ());
    }

    private string sanitize_java_identifier (string raw) {
        var sb = new StringBuilder ();
        for (int i = 0; i < raw.length; i++) {
            char c = raw[i];
            bool valid = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' ||
                         (i > 0 && c >= '0' && c <= '9');
            if (valid) {
                sb.append_c (c);
            }
        }
        return sb.len > 0 ? sb.str : "Main";
    }

    private void open_new_file_dialog () {
        var dialog = new Adw.Window ();
        dialog.set_transient_for (this);
        dialog.set_modal (true);
        dialog.set_default_size (460, 330);
        dialog.set_title ("New File");

        var vbox = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        dialog.set_content (vbox);

        var d_header = new Adw.HeaderBar ();
        var create_btn = new Gtk.Button.with_label ("Create");
        create_btn.add_css_class ("suggested-action");
        d_header.pack_end (create_btn);
        vbox.append (d_header);

        var clamp = new Adw.Clamp ();
        clamp.set_margin_top (18);
        clamp.set_margin_bottom (18);
        clamp.set_margin_start (18);
        clamp.set_margin_end (18);
        vbox.append (clamp);

        var form_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        clamp.set_child (form_box);

        var group = new Adw.PreferencesGroup ();
        group.set_title ("Choose Language Format");
        form_box.append (group);

        string[] labels = new string[LANG_FORMATS.length];
        for (int i = 0; i < LANG_FORMATS.length; i++) {
            labels[i] = LANG_FORMATS[i].label;
        }

        var combo_row = new Adw.ComboRow ();
        combo_row.set_title ("Language");
        combo_row.set_model (new Gtk.StringList (labels));
        combo_row.set_selected (4);
        group.add (combo_row);

        var name_row = new Adw.EntryRow ();
        name_row.set_title ("File Name");
        name_row.set_text (LANG_FORMATS[4].default_name);
        group.add (name_row);

        var holder_row = new Adw.ActionRow ();
        holder_row.set_title ("Copyright Holder");
        holder_row.set_subtitle ("Copyright 2026 " + get_copyright_holder ());
        group.add (holder_row);

        bool updating_name = false;
        combo_row.notify["selected"].connect (() => {
            uint idx = combo_row.get_selected ();
            if (idx < LANG_FORMATS.length) {
                updating_name = true;
                name_row.set_text (LANG_FORMATS[idx].default_name);
                updating_name = false;
            }
        });

        name_row.changed.connect (() => {
            if (updating_name) {
                return;
            }
            string current_text = name_row.get_text ().strip ();
            if (!current_text.contains (".") && current_text != "") {
                uint idx = combo_row.get_selected ();
                if (idx < LANG_FORMATS.length && LANG_FORMATS[idx].ext != "") {
                    updating_name = true;
                    name_row.set_text (current_text + "." + LANG_FORMATS[idx].ext);
                    updating_name = false;
                }
            }
        });

        create_btn.clicked.connect (() => {
            uint idx = combo_row.get_selected ();
            LanguageFormat chosen_fmt = (idx < LANG_FORMATS.length) ? LANG_FORMATS[idx] : LANG_FORMATS[7];

            string chosen_name = name_row.get_text ().strip ();
            if (chosen_name == "") {
                chosen_name = chosen_fmt.default_name;
            }
            if (chosen_fmt.ext != "" && !chosen_name.down ().has_suffix ("." + chosen_fmt.ext)) {
                chosen_name = chosen_name + "." + chosen_fmt.ext;
            }

            dialog.close ();

            var save_dialog = new Gtk.FileDialog ();
            save_dialog.set_initial_name (chosen_name);
            save_dialog.save.begin (this, null, (_obj, res) => {
                try {
                    GLib.File? target_file = save_dialog.save.end (res);
                    if (target_file == null) {
                        return;
                    }
                    string basename = target_file.get_basename () ?? chosen_name;
                    string full_path = target_file.get_path () ??
                        Path.build_filename (target_file.get_parent ()?.get_path () ?? "", basename);
                    string starter_code = build_starter_content (chosen_fmt, basename);

                    if (!write_file_contents (target_file, starter_code)) {
                        return;
                    }

                    syncing_title = true;
                    create_new_tab (target_file, basename, starter_code);
                    syncing_title = false;
                    refresh_active_tab_state ();
                    sync_file_manager_dir_from_active_tab ();
                    save_session_now ();

                    string saved_msg = "saved successfully (%s)".printf (full_path);
                    append_status (saved_msg);
                    select_bottom_tab ("status");
                    show_status_dialog ("Saved", "saved successfully\n\n%s".printf (full_path));
                } catch (Error e) {
                    syncing_title = false;
                    if (!(e is Gtk.DialogError.DISMISSED)) {
                        append_status ("Create file error: %s".printf (e.message));
                        show_status_dialog ("Create File Error", e.message);
                    }
                }
            });
        });

        dialog.present ();
    }

    private void add_shortcut_action (Gtk.ShortcutController ctrl, string accel, owned Gtk.ShortcutFunc cb) {
        ctrl.add_shortcut (new Gtk.Shortcut (
            Gtk.ShortcutTrigger.parse_string (accel),
            new Gtk.CallbackAction ((w, args) => cb (w, args))
        ));
    }

    private void setup_shortcuts () {
        var widget_self = (Gtk.Widget) this;
        var controller = new Gtk.ShortcutController ();
        controller.set_scope (Gtk.ShortcutScope.MANAGED);

        add_shortcut_action (controller, "<Control>n", (w, _args) => { open_new_file_dialog (); return true; });
        add_shortcut_action (controller, "<Control>o", (w, _args) => { on_open_clicked (); return true; });
        add_shortcut_action (controller, "<Control>s", (w, _args) => { save_current_tab (true); return true; });
        add_shortcut_action (controller, "<Control>w", (w, _args) => {
            var page = tab_view.get_selected_page ();
            if (page != null) {
                tab_view.close_page (page);
            }
            return true;
        });
        add_shortcut_action (controller, "<Control>f", (w, _args) => { search_entry.grab_focus (); return true; });
        add_shortcut_action (controller, "<Control>comma", (w, _args) => { open_theme_profiles_dialog (); return true; });
        add_shortcut_action (controller, "<Control>b", (w, _args) => {
            var data = get_current_tab_data ();
            if (data != null) {
                Gtk.TextIter iter;
                data.buffer.get_iter_at_mark (out iter, data.buffer.get_insert ());
                open_line_label_dialog (data, iter.get_line ());
            }
            return true;
        });
        add_shortcut_action (controller, "F8", (w, _args) => { run_action ("compile"); return true; });
        add_shortcut_action (controller, "F9", (w, _args) => { run_action ("make"); return true; });
        add_shortcut_action (controller, "F5", (w, _args) => { run_action ("run"); return true; });

        widget_self.add_controller (controller);

        var save_guard = new Gtk.EventControllerKey ();
        save_guard.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
        save_guard.key_pressed.connect ((keyval, _keycode, state) => {
            var ctrl_only = state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.SHIFT_MASK);
            if (ctrl_only == Gdk.ModifierType.CONTROL_MASK && (keyval == Gdk.Key.s || keyval == Gdk.Key.S)) {
                save_current_tab (true);
                return true;
            }
            return false;
        });
        widget_self.add_controller (save_guard);
    }
}

/* =========================================================================
 * 11. Application Entrypoint
 * ========================================================================= */

public class RookieIdeApp : Adw.Application {
    public RookieIdeApp () {
        Object (
            application_id: "io.github.rookieide.App",
            flags: ApplicationFlags.DEFAULT_FLAGS
        );
    }

    protected override void activate () {
        var display = Gdk.Display.get_default ();
        if (display != null) {
            var icon_theme = Gtk.IconTheme.get_for_display (display);
#if HAVE_VTE
            icon_theme.add_search_path ("/usr/local/share/icons");
            icon_theme.add_search_path ("data/icons");
#else
            string? exe_dir = Environment.get_variable ("MSYSTEM_PREFIX");
            if (exe_dir != null && exe_dir != "") {
                icon_theme.add_search_path (Path.build_filename (exe_dir, "share", "icons"));
            }
            icon_theme.add_search_path ("data/icons");
#endif
        }
        new RookieIdeWindow (this).present ();
    }

    public static int main (string[] args) {
        GLib.Environment.set_application_name ("RookieIDE");
        GLib.Environment.set_prgname ("io.github.rookieide.App");
        GtkSource.init ();
        var app = new RookieIdeApp ();
        int status = app.run (args);
        GtkSource.finalize ();
        return status;
    }
}
