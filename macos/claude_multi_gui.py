"""Tk manager window in the Anthropic look (ivory / slate / clay, serif type). Standard library only; works on macOS and Windows.

Every feature of the CLI is reachable from here: kind, proxy, timezone, palette, provider per window; Init / Check with an output pane;
launch / stop / restart / remove; EN / 中文. Anything that touches the network, the disk in bulk or a subprocess runs on a worker thread
and reports back through a queue, so the UI thread never blocks.
"""
import math, queue, threading, time, traceback, tkinter as tk
from tkinter import colorchooser, messagebox, ttk

IVORY, SLATE, CLAY, CLAY_D, OAT, CLOUD, MID, GRAY, SEL = '#FAF9F5', '#141413', '#D97757', '#C6613F', '#E8E6DC', '#F0EEE6', '#5E5D59', '#87867F', '#F6E7DF'
RED = '#B3261E'
SERIF = 'Georgia'


def hsv_hex(p):
    import colorsys
    r, g, b = colorsys.hsv_to_rgb((p['hue'] % 360) / 360, p['sat'], (p['vMin'] + p['vMax']) / 2)
    return '#%02X%02X%02X' % (int(r * 255), int(g * 255), int(b * 255))


class Btn(tk.Canvas):                       # rounded button drawn by hand (native Aqua buttons ignore colours)
    def __init__(self, master, text, command, primary=False, width=280, height=36):
        super().__init__(master, width=width, height=height, bg='white', highlightthickness=0, cursor='hand2')
        self.text, self.cmd, self.primary, self.w, self.h = text, command, primary, width, height
        self.bind('<Button-1>', lambda e: self.cmd()); self.bind('<Enter>', lambda e: self.draw(True)); self.bind('<Leave>', lambda e: self.draw(False)); self.draw(False)

    def draw(self, hover):
        self.delete('all'); r = 10; fill = (CLAY_D if hover else CLAY) if self.primary else (CLOUD if hover else 'white'); line = CLAY if self.primary else OAT
        pts = [r, 1, self.w - r, 1, self.w - 1, 1, self.w - 1, r, self.w - 1, self.h - r, self.w - 1, self.h - 1, self.w - r, self.h - 1, r, self.h - 1, 1, self.h - 1, 1, self.h - r, 1, r, 1, 1]
        self.create_polygon(pts, smooth=True, fill=fill, outline=line, width=2)
        self.create_text(self.w // 2, self.h // 2, text=self.text, fill='white' if self.primary else SLATE, font=(SERIF, 11))


def card(master, **kw):
    return tk.Frame(master, bg='white', highlightbackground=OAT, highlightthickness=2, **kw)


def build(core):
    """Create the window and return (root, api). `api` exposes the handlers for tests / scripting."""
    cfg = core.read_config(); pal = core.palettes()
    try:
        providers = core.cc_providers()
    except Exception:
        providers = []
    zh = cfg['settings'].get('language') == 'zh'
    L = lambda a, b: a if zh else b
    root = tk.Tk(); root.title(L('Claude 多窗口管理器', 'Claude Multi-Window Manager')); root.configure(bg=IVORY); root.geometry('1240x900'); root.minsize(1240, 900)
    api = {'restart': False}

    # ---- header
    head = tk.Canvas(root, width=70, height=70, bg=IVORY, highlightthickness=0); head.place(x=24, y=14)
    for k in range(12):
        a = k * math.pi / 6; r2 = 17 if k % 2 else 21
        head.create_line(35 + math.cos(a) * 6, 35 + math.sin(a) * 6, 35 + math.cos(a) * r2, 35 + math.sin(a) * r2, fill=CLAY, width=3, capstyle='round')
    tk.Label(root, text=L('Claude 多窗口管理器', 'Multiple windows, different APIs'), bg=IVORY, fg=SLATE, font=(SERIF, 24, 'bold')).place(x=88, y=10)
    tk.Label(root, text=L('官方订阅与第三方 API 同时运行,每个窗口独立图标、代理与时区', 'Official subscription and third-party APIs side by side, one icon, proxy and timezone each'), bg=IVORY, fg=MID, font=(SERIF, 11)).place(x=90, y=60)
    lbl_status = tk.Label(root, text='', bg=IVORY, fg=GRAY, font=(SERIF, 10), anchor='w'); lbl_status.place(x=90, y=84, width=1000)
    tk.Label(root, text='Language / 语言', bg=IVORY, fg=GRAY, font=(SERIF, 10)).place(x=1010, y=26)
    cmb_lang = ttk.Combobox(root, values=['English', '中文'], state='readonly', width=8); cmb_lang.current(1 if zh else 0); cmb_lang.place(x=1120, y=22)

    def status(text, bad=False):
        lbl_status.config(text=f"{time.strftime('%H:%M:%S')}  -  {text}", fg=RED if bad else GRAY)

    def switch_lang(_=None):
        c = core.read_config(); c['settings']['language'] = 'zh' if cmb_lang.current() == 1 else 'en'; core.save_config(c); api['restart'] = True; root.destroy()
    cmb_lang.bind('<<ComboboxSelected>>', switch_lang)

    # ---- windows table
    left = card(root); left.place(x=24, y=108, width=850, height=262)
    tk.Label(left, text=L('窗口', 'Windows'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=18, y=8)
    st = ttk.Style(); st.theme_use('clam')
    st.configure('A.Treeview', background='white', fieldbackground='white', foreground=SLATE, rowheight=34, borderwidth=0, font=(SERIF, 11))
    st.configure('A.Treeview.Heading', background='white', foreground=GRAY, relief='flat', font=(SERIF, 10)); st.map('A.Treeview', background=[('selected', SEL)], foreground=[('selected', SLATE)])
    cols = (('name', L('名称', 'Name'), 130), ('id', 'ID', 62), ('kind', L('类型', 'Kind'), 76), ('provider', L('接口 / 供应商', 'API / provider'), 178),
            ('palette', L('配色', 'Colour'), 82), ('proxy', L('代理', 'Proxy'), 128), ('tz', L('时区', 'Timezone'), 112), ('status', L('状态', 'Status'), 60))
    tv = ttk.Treeview(left, columns=[c[0] for c in cols], show='headings', style='A.Treeview', selectmode='browse')
    for c, t, w in cols:
        tv.heading(c, text=t); tv.column(c, width=w, anchor='w')
    tv.place(x=14, y=40, width=822, height=210)

    prov_text = {'': L('跟随 cc-switch 当前选择', 'Follow cc-switch selection')}
    prov_fmt = {}
    for p in providers:
        fmt = p['meta'].get('apiFormat'); prov_fmt[p['id']] = fmt
        prov_text[p['id']] = p['name'] + (L('  (需经网关)', '  (needs the gateway)') if fmt and fmt != 'anthropic' else L('  (直连上游)', '  (direct)'))
    rows = {i['id']: dict(i) for i in cfg['instances']}
    running_now = {}; deleted = set()
    kind_text = {'official': L('官方', 'Official'), 'cc-switch': L('第三方', 'Third-party')}

    def refresh(keep=None):
        keep = keep or (tv.selection()[0] if tv.selection() else None)
        tv.delete(*tv.get_children())
        for iid, i in rows.items():
            pv = L('官方订阅', 'Official subscription') if core.is_official(i) else prov_text.get(i.get('provider') if i.get('provider') in prov_text else '')
            pids = running_now.get(iid)
            tv.insert('', 'end', iid=iid, values=(i['name'], iid, kind_text[i['kind'] if i['kind'] in kind_text else 'cc-switch'], pv, i.get('palette', ''),
                                                   core.mask_proxy(i.get('proxy')), i.get('timezone', ''), (L('运行中 ', 'running ') + str(pids[0])) if pids else ''))
        if keep in rows:
            tv.selection_set(keep)
        elif tv.get_children():
            tv.selection_set(tv.get_children()[0])
        # Check if official Claude.app updated and clones need rebuild
        outdated_ids = []
        for iid, i in rows.items():
            if not core.is_primary(i):
                outdated, src_v, clone_v = core.check_clone_update(i)
                if outdated:
                    outdated_ids.append((iid, src_v, clone_v))
        if outdated_ids:
            names = ', '.join([f"{iid} ({c_v}->{s_v})" for iid, s_v, c_v in outdated_ids])
            status(L(f'提示: Claude.app 已更新, 实例需要重建: {names}',
                     f'Notice: Claude.app updated, rebuild needed for: {names}'), True)

    # ---- details form (edits the selected row)
    det = card(root); det.place(x=24, y=382, width=850, height=150)
    tk.Label(det, text=L('所选窗口设置', 'Selected window'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=18, y=6)
    v_name, v_kind, v_pal, v_proxy, v_tz, v_prov = (tk.StringVar() for _ in range(6))
    def lab(text, x, y): tk.Label(det, text=text, bg='white', fg=GRAY, font=(SERIF, 9)).place(x=x, y=y)
    X = (18, 300, 582); W = 250
    lab(L('名称', 'Name'), X[0], 34); e_name = ttk.Entry(det, textvariable=v_name); e_name.place(x=X[0], y=54, width=W)
    lab(L('类型', 'Kind'), X[1], 34); c_kind = ttk.Combobox(det, textvariable=v_kind, state='readonly', values=[kind_text['cc-switch'], kind_text['official']]); c_kind.place(x=X[1], y=54, width=W)
    lab(L('配色', 'Palette'), X[2], 34); c_pal = ttk.Combobox(det, textvariable=v_pal, state='readonly', values=list(pal) + [L('自定义颜色…', 'Custom colour...')]); c_pal.place(x=X[2], y=54, width=W)
    lab(L('代理 (http://[用户:密码@]主机:端口)', 'Proxy (http://[user:pass@]host:port)'), X[0], 88); e_proxy = ttk.Entry(det, textvariable=v_proxy); e_proxy.place(x=X[0], y=108, width=W)
    lab(L('时区 (IANA,可手输)', 'Timezone (IANA, type or pick)'), X[1], 88); c_tz = ttk.Combobox(det, textvariable=v_tz, values=[''] + core.COMMON_TIMEZONES); c_tz.place(x=X[1], y=108, width=W)
    lab(L('接口 / 供应商', 'API / provider'), X[2], 88); c_prov = ttk.Combobox(det, textvariable=v_prov, state='readonly', values=list(prov_text.values())); c_prov.place(x=X[2], y=108, width=W)
    loading = [False]

    def sel_id():
        s = tv.selection()
        return s[0] if s else None

    def load_form(_=None):
        iid = sel_id()
        if not iid:
            return
        i = rows[iid]; loading[0] = True
        v_name.set(i['name']); v_kind.set(kind_text['official' if core.is_official(i) else 'cc-switch']); v_pal.set(i.get('palette', ''))
        v_proxy.set(i.get('proxy', '')); v_tz.set(i.get('timezone', '')); v_prov.set(prov_text[i.get('provider') if i.get('provider') in prov_text else ''])
        prim = core.is_primary(i)
        c_kind.config(state='disabled' if prim else 'readonly'); c_pal.config(state='disabled' if prim else 'readonly')
        c_prov.config(state='disabled' if core.is_official(i) else 'readonly')
        loading[0] = False; draw_preview()

    def commit_form(strict=False):
        """Write the form back into the selected row. Invalid proxy / timezone: raise when strict, else show in the status line."""
        iid = sel_id()
        if not iid or loading[0] or iid not in rows:
            return True
        i = rows[iid]
        try:
            proxy = core.normalize_proxy(v_proxy.get()); tz = core.validate_timezone(v_tz.get())
        except core.ClaudeMultiError as e:
            if strict:
                raise
            status(str(e), True); return False
        i['name'] = v_name.get().strip() or i['name']
        for k, v in (('proxy', proxy), ('timezone', tz)):
            if v: i[k] = v
            else: i.pop(k, None)
        if not core.is_primary(i):
            i['kind'] = 'official' if v_kind.get() == kind_text['official'] else 'cc-switch'
            if v_pal.get() in pal or core.re.fullmatch(r'#[0-9A-Fa-f]{6}', v_pal.get() or ''):
                i['palette'] = v_pal.get()
            if core.is_official(i):
                i.pop('provider', None)
            else:
                pid = next((k for k, t in prov_text.items() if t == v_prov.get()), '')
                if pid and prov_fmt.get(pid) and prov_fmt[pid] != 'anthropic':
                    messagebox.showinfo('', L('该供应商使用非 Anthropic 接口,必须经 cc-switch 网关,不能直连。', 'This provider is not Anthropic-format and must go through the cc-switch gateway; it cannot be used directly.'))
                elif pid: i['provider'] = pid
                else: i.pop('provider', None)
        refresh(iid); return True

    def on_pal(_=None):
        if loading[0]:
            return
        if v_pal.get() == L('自定义颜色…', 'Custom colour...'):
            c = colorchooser.askcolor()[1]
            v_pal.set(c.upper() if c else rows[sel_id()].get('palette', ''))
        commit_form()
    for w in (e_name, e_proxy, c_tz):
        w.bind('<FocusOut>', lambda e: commit_form()); w.bind('<Return>', lambda e: commit_form())
    c_tz.bind('<<ComboboxSelected>>', lambda e: commit_form()); c_kind.bind('<<ComboboxSelected>>', lambda e: (commit_form(), load_form()))
    c_pal.bind('<<ComboboxSelected>>', on_pal); c_prov.bind('<<ComboboxSelected>>', lambda e: commit_form())

    # ---- side card: preview + actions
    right = card(root); right.place(x=894, y=108, width=322, height=424)
    prev = tk.Canvas(right, width=96, height=96, bg='white', highlightthickness=0); prev.place(x=18, y=14)
    tk.Label(right, text=L('图标预览', 'Icon preview'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=126, y=22)
    tk.Label(right, text=L('Dock 与桌面', 'Dock and desktop'), bg='white', fg=GRAY, font=(SERIF, 10)).place(x=126, y=52)

    def draw_preview():
        iid = sel_id()
        if not iid:
            return
        spec = rows[iid].get('palette', 'official')
        try:
            color = CLAY if spec == 'official' or core.is_primary(rows[iid]) else hsv_hex(core.resolve_palette(spec, pal))
        except core.ClaudeMultiError:
            color = GRAY
        prev.delete('all'); prev.create_rectangle(4, 4, 92, 92, fill=color, outline=color, width=2)
        for k in range(12):
            a = k * math.pi / 6; r2 = 30 if k % 2 else 38
            prev.create_line(48 + math.cos(a) * 9, 48 + math.sin(a) * 9, 48 + math.cos(a) * r2, 48 + math.sin(a) * r2, fill='white', width=4, capstyle='round')
    tv.bind('<<TreeviewSelect>>', load_form)

    # ---- output pane
    outc = card(root); outc.place(x=24, y=544, width=1192, height=216)
    tk.Label(outc, text=L('输出', 'Output'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=18, y=6)
    txt = tk.Text(outc, bg=IVORY, fg=SLATE, font=('Menlo', 10), relief='flat', wrap='word', height=8, state='disabled', highlightthickness=0)
    sb = ttk.Scrollbar(outc, command=txt.yview); txt.config(yscrollcommand=sb.set)
    txt.place(x=14, y=36, width=1140, height=168); sb.place(x=1158, y=36, height=168)

    def emit(line):
        txt.config(state='normal'); txt.insert('end', core.mask_secrets(line) + '\n'); txt.see('end'); txt.config(state='disabled')
    Btn(outc, L('清空', 'Clear'), lambda: (txt.config(state='normal'), txt.delete('1.0', 'end'), txt.config(state='disabled')), width=70, height=26).place(x=1100, y=6)

    # ---- worker threads (never touch widgets from them: post to the queue)
    q = queue.Queue(); busy = [0]

    def bg(label, fn, done=None):
        busy[0] += 1; status(label + ' ...')
        def work():
            try:
                res = fn(lambda s: q.put(('out', s)))
                q.put(('done', done, res, label))
            except core.ClaudeMultiError as e:
                q.put(('err', str(e), label))
            except Exception as e:                                # a bug, not a user error: keep the traceback in the log
                core.log_line(traceback.format_exc()); q.put(('err', f'{type(e).__name__}: {e}', label))
        threading.Thread(target=work, daemon=True).start()

    def pump():
        try:
            while True:
                m = q.get_nowait()
                if m[0] == 'out': emit(m[1])
                elif m[0] == 'status': running_now.clear(); running_now.update(m[1]); refresh()
                elif m[0] == 'done':
                    busy[0] -= 1; status(m[3] + ' - ' + L('完成', 'done'))
                    if m[1]: m[1](m[2])
                elif m[0] == 'err':
                    busy[0] -= 1; emit('error: ' + m[1]); status(m[2] + ' - ' + L('失败', 'failed') + ': ' + core.mask_secrets(m[1])[:160], True)
                    messagebox.showerror('', core.mask_secrets(m[1]))
        except queue.Empty:
            pass
        root.after(100, pump)

    polling = [False]
    def poll_now():
        if core.IS_MAC and not polling[0]:
            polling[0] = True
            def work():
                try:
                    q.put(('status', {iid: [p for p, _ in core.running(i)] for iid, i in list(rows.items())}))
                except Exception:
                    pass
                polling[0] = False
            threading.Thread(target=work, daemon=True).start()

    def poll_status():
        poll_now(); root.after(3000, poll_status)

    # ---- actions
    v_sync, v_live, v_off = tk.BooleanVar(value=cfg['settings']['syncSessions']), tk.BooleanVar(value=cfg['settings']['liveRefresh']), tk.BooleanVar(value=cfg['settings']['refreshOfficial'])

    def save_all(strict=True):
        commit_form(strict)
        c = core.read_config()
        merged = [dict(r) for r in rows.values()]                      # our rows win for ids we know ...
        merged += [i for i in c['instances'] if i['id'] not in rows and i['id'] not in deleted]     # ... windows added elsewhere meanwhile survive
        c['instances'] = merged
        c['settings'].update(syncSessions=v_sync.get(), liveRefresh=v_live.get(), refreshOfficial=v_off.get()); core.save_config(c)
        deleted.clear()

    def guarded(fn):
        def w(*a):
            try: fn(*a)
            except Exception as e:                                    # user errors and bugs alike end up in the output pane, never in a silent Tk callback
                msg = core.mask_secrets(e if str(e) else type(e).__name__)
                if not isinstance(e, core.ClaudeMultiError):
                    core.log_line(traceback.format_exc()); msg = f'{type(e).__name__}: {msg}'
                emit('error: ' + msg); status(msg[:160], True); messagebox.showerror('', msg)
        return w

    def add(official):
        n = 2
        while f'x{n}' in rows: n += 1
        used = {i.get('palette') for i in rows.values()}; p = next((x for x in pal if x not in used), list(pal)[n % len(pal)])
        rows[f'x{n}'] = dict(id=f'x{n}', name=(f'Claude Official {n}' if official else f'Claude 3P {n}'), kind='official' if official else 'cc-switch', palette=p)
        save_all(); refresh(f'x{n}'); status(L('已添加。点“初始化”创建环境。', 'Added. Press Init to provision it.'))

    def remove():
        iid = sel_id()
        if not iid: return
        if core.is_primary(rows[iid]):
            messagebox.showinfo('', L('主官方窗口不能删除。', 'The primary official window cannot be removed.')); return
        if not messagebox.askyesno('', L('删除该窗口?(其数据目录保留)', 'Remove this window? (its data directory is kept)')): return
        commit_form(True)                                             # flush the form while the row still exists
        i = rows.pop(iid); deleted.add(iid); tv.selection_set(()); save_all(); refresh()
        def work(out):
            app = core.clone_path(i)
            if app.exists(): core.shutil.rmtree(app, ignore_errors=True)
            out(f"removed '{iid}'")
        bg(L('删除', 'Remove'), work)

    def targets_selected():
        iid = sel_id()
        if not iid: raise core.ClaudeMultiError(L('请先选择一个窗口。', 'Select a window first.'))
        return dict(rows[iid])

    def apply_all():
        save_all()
        items = [dict(i) for i in rows.values()]
        def work(out):
            for i in items:
                out(f"[{i['id']}] " + L('初始化…', 'provisioning...'))
                r = core.provision(i, out=out, force=False)
                out(f"    data={r['data_dir']}  mcp={r['mcp']}  sessions={r['sessions']}  clone={r['clone'] or '-'}")
        bg(L('应用更改', 'Apply changes'), work)

    def init_sel():
        save_all(); i = targets_selected()
        def work(out):
            r = core.provision(i, out=out, force=True)
            out(f"[{i['id']}] data={r['data_dir']}  mcp={r['mcp']}  sessions={r['sessions']}  clone={r['clone'] or '-'}")
        bg(L('初始化', 'Init'), work)

    def check_sel():
        save_all(); i = targets_selected()
        def work(out):
            out(L('正在检测出口 IP、风险与时区(经该窗口的代理)…', 'Checking egress IP, risk and timezone through this window\'s proxy...'))
            for line in core.format_check(core.check_instance(i)): out(line)
            out('')
        bg(L('检测', 'Check'), work)

    def launch_sel():
        save_all(); i = targets_selected()
        bg(L('启动', 'Launch'), lambda out: core.launch(i, out=out), lambda _: root.after(2500, poll_now))

    def launch_all():
        save_all(); items = [dict(i) for i in rows.values()]
        def work(out):
            for i in items:
                core.launch(i, out=out); time.sleep(2)
        bg(L('全部启动', 'Launch all'), work, lambda _: root.after(2500, poll_now))

    def stop_sel():
        save_all(); i = targets_selected()
        bg(L('停止', 'Stop'), lambda out: out(L('已停止', 'stopped') if core.stop(i) else L('10 秒后仍在运行', 'still running after 10 s')), lambda _: root.after(2500, poll_now))

    def restart_sel():
        save_all(); i = targets_selected()
        if core.IS_MAC and core.running(i) and not messagebox.askyesno('', L('将重启该窗口,未发送的草稿会丢失。继续?', 'This restarts the window; unsent drafts are lost. Continue?')): return
        bg(L('重启', 'Restart'), lambda out: core.restart(i, out=out), lambda _: root.after(2500, poll_now))

    def sync_now():
        save_all()
        def work(out):
            sess_copied = core.sync_sessions(core.read_config(), {})
            mcp_updated = core.sync_mcp_servers()
            out(L(f'已同步会话: {sess_copied} 个文件, MCP 配置: {mcp_updated} 个实例',
                  f'Synced sessions: {sess_copied} file(s), MCP configs: {mcp_updated} instance(s)'))
        bg(L('同步会话', 'Sync sessions'), work)

    def doctor_now():
        def work(out):
            out("=== " + L('运行环境诊断', 'Running Environment Doctor') + " ===")
            results = core.run_doctor()
            passes = sum(1 for r in results if r['status'] == 'PASS')
            warns = sum(1 for r in results if r['status'] == 'WARN')
            fails = sum(1 for r in results if r['status'] == 'FAIL')
            for r in results:
                badge = f"[{r['status']}]"
                out(f"{badge:<7} {r['name']}: {r['message']}")
                if r.get('remediation'):
                    out("        " + L('修复: ', 'Fix: ') + r['remediation'])
            out('')
            out(f"Summary: {passes} PASS, {warns} WARN, {fails} FAIL")
            if fails == 0 and warns == 0:
                out(L('所有检查通过！环境就绪。', 'All checks passed! Environment is healthy.'))
            elif fails == 0:
                out(L('存在警告，请查看上方提示。', 'Warnings found. Review recommendations above.'))
            else:
                out(L('存在未满足的硬性条件，请先修复。', 'Failures found. Please remediate before running.'))
        bg(L('诊断', 'Doctor'), work)

    def open_folder():
        core.HOME_ROOT.mkdir(parents=True, exist_ok=True)
        if core.IS_MAC:
            subprocess.run(['open', str(core.HOME_ROOT)])
        else:
            try:
                os.startfile(str(core.HOME_ROOT))
            except Exception:
                pass

    def list_refresh():
        c = core.read_config(); deleted.clear(); rows.clear(); rows.update({i['id']: dict(i) for i in c['instances']}); refresh(); load_form(); status(L('列表已刷新。', 'List refreshed.'))

    bw, bx = 136, (18, 168)
    spec = [(L('+ 第三方', '+ 3P'), lambda: add(False), False), (L('+ 官方', '+ Official'), lambda: add(True), False),
            (L('删除所选', 'Remove'), guarded(remove), False), (L('应用更改', 'Apply'), guarded(apply_all), False),
            (L('初始化', 'Init'), guarded(init_sel), False), (L('检测 IP', 'Check'), guarded(check_sel), False),
            (L('启动所选', 'Launch'), guarded(launch_sel), True), (L('停止', 'Stop'), guarded(stop_sel), False),
            (L('重启', 'Restart'), guarded(restart_sel), False), (L('全部启动', 'Launch all'), guarded(launch_all), False),
            (L('同步会话', 'Sync sessions'), guarded(sync_now), False), (L('环境诊断', 'Doctor'), guarded(doctor_now), False),
            (L('打开目录', 'Open folder'), open_folder, False), (L('刷新列表', 'Refresh list'), guarded(list_refresh), False)]
    for k, (t, f, prim) in enumerate(spec):
        Btn(right, t, f, primary=prim, width=bw, height=32).place(x=bx[k % 2], y=118 + (k // 2) * 44)
    api.update(add=add, remove=guarded(remove),commit=commit_form, select=lambda iid: (tv.selection_set(iid), load_form()), rows=rows, check=check_sel, init=init_sel, save=save_all, pump=pump, queue=q, txt=txt, tv=tv, busy=busy,
               form=dict(name=v_name, kind=v_kind, pal=v_pal, proxy=v_proxy, tz=v_tz, prov=v_prov), emit=emit, status=status)

    # ---- behaviour card
    bot = card(root); bot.place(x=24, y=772, width=1192, height=112)
    tk.Label(bot, text=L('同步与行为', 'Sync and behaviour'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=18, y=4)
    for k, (v, t) in enumerate(((v_sync, L('在各窗口间同步会话(后台)', 'Sync sessions across windows (background)')),
                                (v_live, L('实时刷新:空闲且不在前台的窗口会在后台静默重启以载入新会话', 'Live refresh: idle, unfocused windows restart silently to load new sessions')),
                                (v_off, L('同时对官方窗口启用实时刷新(默认关闭)', 'Also live-refresh the official windows (off by default)')))):
        tk.Checkbutton(bot, text=t, variable=v, bg='white', fg=SLATE, activebackground='white', font=(SERIF, 10), anchor='w', command=lambda: save_all(False)).place(x=14, y=28 + k * 25)
    tk.Label(bot, text=L('macOS 版为实验性(未在真机验证):固定/星标同步与 claude:// 路由暂未移植;代理/时区经进程环境变量注入。', 'macOS port is experimental (not verified on real hardware): pin sync and claude:// routing are not ported; proxy/timezone are injected via process environment.'),
             bg='white', fg=GRAY, font=(SERIF, 9)).place(x=560, y=34, width=620, height=60)

    refresh(); load_form()
    root.after(100, pump); root.after(500, poll_status)

    if not rows:
        def show_onboard():
            msg = L(
                "欢迎使用 Claude 多开管理器！\n\n"
                "检测到尚未配置多开实例。\n"
                "• 点击 '+ 官方' 或 '+ 第三方' 即可创建独立窗口\n"
                "• 每个窗口拥有独立 Cookie、代理、会话与数据目录\n"
                "• 点击 '环境诊断' 可检查当前环境与依赖\n\n"
                "是否立即运行一次环境诊断？",
                "Welcome to Claude Multi Manager!\n\n"
                "No instances configured yet.\n"
                "• Click '+ Official' or '+ 3P' to create isolated windows\n"
                "• Each instance has its own cookies, proxy, session & data dir\n"
                "• Click 'Doctor' to verify your environment & dependencies\n\n"
                "Run environment doctor now?"
            )
            if messagebox.askyesno(L('首次运行向导', 'First Run Onboarding'), msg):
                doctor_now()
        root.after(400, show_onboard)

    status(L('就绪。', 'Ready.') + ('' if core.IS_MAC else L(' (非 macOS:只能编辑配置、初始化目录和检测 IP)', ' (not macOS: config editing, directory init and IP check only)')))
    return root, api


def run(core):
    while True:
        root, api = build(core)
        root.mainloop()
        if not api['restart']:
            break
