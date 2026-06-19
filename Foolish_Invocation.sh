import os
import sys
import json
import shutil
import subprocess
import tkinter as tk
from tkinter import ttk, messagebox
import threading
from pathlib import Path

# --- Constants & Paths ---
HOME = Path.home()
HYPR_DIR = HOME / ".config/hypr"
REPO_DIR = HOME / ".local/share/hypr_theme_engine/repo"

# Renamed Configuration Targets
KEYBINDS_FILE = HYPR_DIR / "Foolish_Keybinds.conf"
THEME_FILE = HYPR_DIR / "Foolish_Theme.conf"
LAYOUT_FILE = HYPR_DIR / "Foolish_Layout.conf"

# YOUR GitHub Repository
DEFAULT_REPO_URL = "https://github.com/MichaelWard405/Foolish-Alteration.git"

HYPR_DIR.mkdir(parents=True, exist_ok=True)
REPO_DIR.parent.mkdir(parents=True, exist_ok=True)

class HyprSetupWizard:
    def __init__(self, root):
        self.root = root
        self.root.title("Hyprland Setup Engine | Foolish-Alteration")
        self.root.geometry("600x500")
        
        # Strictly empty initializations; populated ONLY by GitHub
        self.themes, self.layouts, self.keybinds, self.package_packs = [], [], [], []
        self.selected_theme, self.selected_layout, self.selected_keybind = "", "", ""
        self.selected_packages = [] 
        
        self.current_step = 1
        self.main_container = ttk.Frame(self.root, padding=20)
        self.main_container.pack(fill='both', expand=True)
        
        self.sync_repository()

    def clear_container(self):
        for widget in self.main_container.winfo_children(): widget.destroy()

    def sync_repository(self):
        self.clear_container()
        ttk.Label(self.main_container, text="Fetching Foolish-Alteration...", font=("Helvetica", 14, "bold")).pack(pady=50)
        progress = ttk.Progressbar(self.main_container, mode='indeterminate')
        progress.pack(fill='x', padx=50, pady=10)
        progress.start()
        self.root.update()

        def task():
            try:
                if REPO_DIR.exists():
                    subprocess.run(["git", "-C", str(REPO_DIR), "pull"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    subprocess.run(["git", "clone", DEFAULT_REPO_URL, str(REPO_DIR)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception as e: 
                print(f"Git sync failed: {e}")
            
            self.scan_repository_data()
            self.root.after(0, self.render_current_step)

        threading.Thread(target=task, daemon=True).start()

    def scan_repository_data(self):
        if not REPO_DIR.exists(): return
        
        theme_dir = REPO_DIR / "themes"
        if theme_dir.exists():
            self.themes = [d.name for d in theme_dir.iterdir() if d.is_dir()]
            if self.themes: self.selected_theme = self.themes[0]

        layout_dir = REPO_DIR / "layouts"
        if layout_dir.exists():
            self.layouts = [d.name for d in layout_dir.iterdir() if d.is_dir()]
            if self.layouts: self.selected_layout = self.layouts[0]

        keybind_dir = REPO_DIR / "keybinds"
        if keybind_dir.exists():
            self.keybinds = [f.name for f in keybind_dir.iterdir() if f.is_file() and not f.name.startswith('.')]
            if self.keybinds: self.selected_keybind = self.keybinds[0]

        pkg_dir = REPO_DIR / "packages"
        if pkg_dir.exists():
            self.package_packs = [f.stem for f in pkg_dir.glob("*.json")]

    def next_step(self):
        self.current_step += 1
        self.render_current_step()

    def prev_step(self):
        self.current_step -= 1
        self.render_current_step()

    def render_current_step(self):
        self.clear_container()
        if self.current_step == 1: self.render_selection_step("Choose a Custom Theme", "Select from your custom configuration packs:", self.themes, "theme")
        elif self.current_step == 2: self.render_selection_step("Choose a Window Layout", "Select your custom tiling parameters:", self.layouts, "layout")
        elif self.current_step == 3: self.render_selection_step("Choose Operational Keybinds", "Select your shortcut layout profile:", self.keybinds, "keybind")
        elif self.current_step == 4: self.render_package_step()
        elif self.current_step == 5: self.render_summary_step()

    def render_selection_step(self, title_text, desc_text, items, selection_type):
        ttk.Label(self.main_container, text=title_text, font=("Helvetica", 14, "bold")).pack(pady=10)
        ttk.Label(self.main_container, text=desc_text).pack(pady=5)
        
        if not items:
            ttk.Label(self.main_container, text="⚠️ No files found in GitHub repository for this category.", foreground="red").pack(pady=10)
            items = ["Missing Data"]
            
        current_val = getattr(self, f"selected_{selection_type}")
        var = tk.StringVar(value=current_val if current_val else items[0])
        ttk.Combobox(self.main_container, textvariable=var, values=items, state="readonly", width=40).pack(pady=20)
        
        def save_and_next():
            setattr(self, f"selected_{selection_type}", var.get())
            self.next_step()
            
        self.build_navigation_buttons(save_and_next)

    def render_package_step(self):
        ttk.Label(self.main_container, text="Select Extensible Package Packs", font=("Helvetica", 14, "bold")).pack(pady=10)
        ttk.Label(self.main_container, text="Check any workflow application bundles you want initialized right now:").pack(pady=5)

        chk_frame = ttk.Frame(self.main_container)
        chk_frame.pack(pady=15, fill='both', expand=True)

        if not self.package_packs:
            ttk.Label(chk_frame, text="No package packs found in the repository.", font=("Helvetica", 10, "italic")).pack(pady=20)

        checkbox_vars = {}
        for pack in self.package_packs:
            var = tk.BooleanVar(value=(pack in self.selected_packages))
            checkbox_vars[pack] = var
            ttk.Checkbutton(chk_frame, text=f" {pack.title()} Environment Pack", variable=var).pack(anchor='w', padx=20, pady=4)

        def save_and_next():
            self.selected_packages = [pack for pack, var in checkbox_vars.items() if var.get()]
            self.next_step()

        self.build_navigation_buttons(save_and_next)

    def render_summary_step(self):
        ttk.Label(self.main_container, text="Review Your Completed Setup Blueprint", font=("Helvetica", 14, "bold")).pack(pady=10)
        summary_text = f"• Selected Theme: {self.selected_theme}\n• Selected Window Layout: {self.selected_layout}\n• Selected Keybindings: {self.selected_keybind}\n• Active Additional Modules: {', '.join(self.selected_packages) if self.selected_packages else 'None'}"
        ttk.Label(self.main_container, text=summary_text, justify='left', font=("Courier", 10)).pack(pady=20, fill='x')
        ttk.Button(self.main_container, text="COMPILE & INJECT BLANKET SYSTEM CONFIG", command=self.apply_engine).pack(pady=20, ipady=10, fill='x')
        self.build_navigation_buttons(None)

    def build_navigation_buttons(self, next_callback):
        nav_frame = ttk.Frame(self.main_container)
        nav_frame.pack(side='bottom', fill='x', pady=10)
        if self.current_step > 1: ttk.Button(nav_frame, text="◀ Back", command=self.prev_step).pack(side='left', padx=5)
        if next_callback: ttk.Button(nav_frame, text="Next ▶", command=next_callback).pack(side='right', padx=5)

    def apply_engine(self):
        theme_data = self.resolve_theme_data(self.selected_theme)
        deps = theme_data.get('dependencies', [])
        
        for pack in self.selected_packages:
            pkg_file = REPO_DIR / "packages" / f"{pack}.json"
            if pkg_file.exists():
                try: deps.extend(json.loads(pkg_file.read_text()).get('packages', []))
                except: pass

        self.clear_container()
        ttk.Label(self.main_container, text="Installing Dependencies...", font=("Helvetica", 14, "bold")).pack(pady=40)
        ttk.Label(self.main_container, text="Running silently in the background. Do not close.").pack(pady=5)
        progress = ttk.Progressbar(self.main_container, mode='indeterminate')
        progress.pack(fill='x', padx=50, pady=20)
        progress.start()
        self.root.update()

        def runner():
            try:
                if deps: subprocess.run(["yay", "-S", "--needed", "--noconfirm"] + list(set(deps)), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.root.after(0, lambda: self.execute_local_apply(theme_data))
            except Exception as e:
                self.root.after(0, lambda: messagebox.showerror("Install Error", f"Failed to install: {e}"))
                self.root.destroy()

        threading.Thread(target=runner, daemon=True).start()

    def resolve_theme_data(self, theme_name):
        if not theme_name or theme_name == "Missing Data": return {}
        t_json = REPO_DIR / "themes" / theme_name / "theme.json"
        if t_json.exists():
            try: return json.loads(t_json.read_text())
            except Exception as e: print(f"Error parsing JSON: {e}")
        return {}

    def run_cmd(self, cmd): subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def execute_local_apply(self, t_data):
        try:
            # Fallbacks safely default to standard Adwaita if you haven't filled out your JSON yet
            gtk_theme = t_data.get('gtk_theme', 'Adwaita')
            icon_theme = t_data.get('icon_theme', 'Adwaita')
            cursor_theme = t_data.get('cursor_theme', 'Adwaita')
            font_name = t_data.get('font_name', 'Sans 11')
            
            # 1. Bind Native Desktop Themes
            self.run_cmd(["gsettings", "set", "org.gnome.desktop.interface", "gtk-theme", gtk_theme])
            self.run_cmd(["gsettings", "set", "org.gnome.desktop.interface", "icon-theme", icon_theme])
            self.run_cmd(["gsettings", "set", "org.gnome.desktop.interface", "cursor-theme", cursor_theme])
            self.run_cmd(["gsettings", "set", "org.gnome.desktop.interface", "font-name", font_name])

            # 2. Inject Sandbox Permissions & CSS
            if "colors" in t_data:
                self.compile_gtk_css(t_data["colors"])
                self.patch_terminal_and_cli(t_data["colors"])
            self.patch_qt5ct(t_data)

            self.run_cmd(["flatpak", "override", "--user", f"--env=GTK_THEME={gtk_theme}"])
            self.run_cmd(["flatpak", "override", "--user", f"--env=ICON_THEME={icon_theme}"])
            self.run_cmd(["flatpak", "override", "--user", "--filesystem=~/.themes:ro"])
            self.run_cmd(["flatpak", "override", "--user", "--filesystem=~/.icons:ro"])
            self.run_cmd(["flatpak", "override", "--user", "--filesystem=~/.local/share/icons:ro"])
            self.run_cmd(["flatpak", "override", "--user", "--filesystem=xdg-config/gtk-3.0"])
            self.run_cmd(["flatpak", "override", "--user", "--filesystem=xdg-config/gtk-4.0"])

            # 3. Deploy assets written by you on GitHub
            self.deploy_github_assets(self.selected_theme)
            self.write_hypr_confs(t_data)
            self.replace_main_hyprland_conf()
            
            # 4. Refresh Environments
            self.run_cmd(["killall", "waybar"])
            subprocess.Popen(["waybar"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            self.run_cmd(["hyprctl", "reload"])
            self.run_cmd(["hyprctl", "setcursor", cursor_theme, "24"])
            
            messagebox.showinfo("Success", "Assets deployed! Your custom styles, icons, and layout updates are now active.")
            self.root.destroy()
        except Exception as e:
            messagebox.showerror("Error During Compilation", str(e))
            self.root.destroy()

    def compile_gtk_css(self, colors):
        bg = f"#{colors.get('background', '282828')}"
        fg = f"#{colors.get('foreground', 'ebdbb2')}"
        accent = f"#{colors.get('active_border', 'd3869b')}"
        
        css_payload = f"""/* DYNAMICALLY COMPILED GTK THEME */
@define-color theme_bg_color {bg};
@define-color theme_base_color {bg};
@define-color theme_fg_color {fg};
@define-color theme_text_color {fg};
@define-color theme_selected_bg_color {accent};
@define-color theme_selected_fg_color {bg};
@define-color accent_color {accent};
@define-color accent_bg_color {accent};
@define-color accent_fg_color {bg};
"""
        for v in ["3.0", "4.0"]:
            gtk_dir = HOME / f".config/gtk-{v}"
            gtk_dir.mkdir(parents=True, exist_ok=True)
            css_file = gtk_dir / "gtk.css"
            
            existing_css = css_file.read_text() if css_file.exists() else ""
            if "/* DYNAMICALLY COMPILED GTK THEME */" in existing_css:
                existing_css = existing_css.split("/* DYNAMICALLY COMPILED GTK THEME */")[0].strip()
            
            css_file.write_text(f"{existing_css}\n\n{css_payload}".strip())

    def patch_qt5ct(self, t_data):
        qt5ct_dir = HOME / ".config/qt5ct"
        qt5ct_dir.mkdir(parents=True, exist_ok=True)
        qt5ct_conf = qt5ct_dir / "qt5ct.conf"
        icon_theme = t_data.get('icon_theme', 'Adwaita')
        conf_content = f"[Appearance]\nicon_theme={icon_theme}\nstyle=gtk2\n"
        qt5ct_conf.write_text(conf_content)

    def patch_terminal_and_cli(self, colors):
        bg = f"#{colors.get('background', '282828')}"
        fg = f"#{colors.get('foreground', 'ebdbb2')}"
        accent = f"#{colors.get('active_border', 'd3869b')}"

        kitty_dir = HOME / ".config/kitty"
        kitty_dir.mkdir(parents=True, exist_ok=True)
        (kitty_dir / "theme.conf").write_text(f"background {bg}\nforeground {fg}\nselection_background {accent}\nactive_border_color {accent}\n")
        
        main_kitty = kitty_dir / "kitty.conf"
        content = main_kitty.read_text() if main_kitty.exists() else ""
        if "include theme.conf" not in content:
            main_kitty.write_text("include theme.conf\n" + content)

        lg_dir = HOME / ".config/lazygit"
        lg_dir.mkdir(parents=True, exist_ok=True)
        lg_theme = f"gui:\n  theme:\n    activeBorderColor:\n      - \"{accent}\"\n      - bold\n    inactiveBorderColor:\n      - \"{bg}\"\n    selectedLineBgColor:\n      - \"{bg}\"\n"
        (lg_dir / "config.yml").write_text(lg_theme)

    def deploy_github_assets(self, theme_name):
        if not theme_name or theme_name == "Missing Data": return
        theme_dir = REPO_DIR / "themes" / theme_name
        
        deployment_map = {
            "wofi.css": HOME / ".config/wofi/style.css",
            "waybar.css": HOME / ".config/waybar/style.css",
            "waybar.json": HOME / ".config/waybar/config",
            "wlogout.css": HOME / ".config/wlogout/style.css",
            "wlogout.json": HOME / ".config/wlogout/layout"
        }
        
        for filename, dest in deployment_map.items():
            source = theme_dir / filename
            if source.exists():
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(source, dest)

    def write_hypr_confs(self, t_data):
        layout_src = REPO_DIR / "layouts" / self.selected_layout / "layout.conf"
        LAYOUT_FILE.write_text(layout_src.read_text() if layout_src.exists() else "")
        
        keybind_src = REPO_DIR / "keybinds" / self.selected_keybind
        KEYBINDS_FILE.write_text(keybind_src.read_text() if keybind_src.exists() else "")

        colors = t_data.get("colors", {})
        c_active = colors.get("active_border", "ffffff")
        c_inactive = colors.get("inactive_border", "000000")
        cursor = t_data.get('cursor_theme', 'Adwaita')

        compiled_hypr = f"general {{\n    col.active_border = rgba({c_active}ee)\n    col.inactive_border = rgba({c_inactive}aa)\n}}\n"
        compiled_hypr += f"env = XCURSOR_THEME,{cursor}\nexec-once = hyprctl setcursor {cursor} 24\n"
        
        THEME_FILE.write_text(compiled_hypr)

    def replace_main_hyprland_conf(self):
        main_conf = HYPR_DIR / "hyprland.conf"
        base_config = """# ==========================================================
# AUTOMATICALLY GENERATED BY FOOLISH-ALTERATION
# ==========================================================

source = ~/.config/hypr/Foolish_Theme.conf
source = ~/.config/hypr/Foolish_Layout.conf
source = ~/.config/hypr/Foolish_Keybinds.conf

monitor=,preferred,auto,auto

input {
    kb_layout = us
    follow_mouse = 1
    touchpad { natural_scroll = false }
    sensitivity = 0
}

misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

# Boot Sequence
exec-once = waybar
exec-once = kitty bash -c "curl -sO https://raw.githubusercontent.com/MichaelWard405/Foolish-Alteration/main/Foolish_Alteration.py && chmod +x Foolish_Alteration.py && python3 Foolish_Alteration.py"
"""
        main_conf.write_text(base_config)

if __name__ == "__main__":
    root = tk.Tk()
    app = HyprSetupWizard(root)
    root.mainloop()
