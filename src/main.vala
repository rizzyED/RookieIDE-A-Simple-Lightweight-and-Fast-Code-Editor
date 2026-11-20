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
