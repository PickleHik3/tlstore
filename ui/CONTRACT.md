# tlstore-ui contract (Revision 9) — header, Front, Item, Installing, the store updating itself

crate tlstore_ui — use tlstore_ui::{app::*, render::*, layout::*, palette::*, picture::*, term::{Event,Key,Mouse,MouseKind,Size,Caps}};
app::run(first: Box<dyn Screen>, Options::default()) -> io::Result<()>  // opens tty, probes (≤150ms), loops, restores; Ctrl-C/SIGTERM quit
trait Screen { draw(&mut self, f:&mut Frame); handle(&mut self, ev:&Event, ctx:&mut Ctx)->Nav; animating()->bool; tick(now,ctx)->bool; watch()->Vec<RawFd>;
  finished()->bool /*asked after every tick: true ends the loop as a quit does, terminal restored*/ }
Ctx { size: Size{cols,rows,cell_w,cell_h}, caps: Caps, palette: Palette, pics: Pictures, motion: bool /*TLSTORE_MOTION!=0*/, home, cell_known }
Event { Key(Key), Mouse(Mouse{kind,button,col,row,..}), Resize(Size), Tap{action:ActionId,col,row}, Readable(RawFd), Reply(_) }
Frame (fresh blank each draw; all clipped): f.text/text_clip/text_right/text_centred, f.fill, f.hline, f.sized(x,y,s,Sizing,st)->Rect (OSC 66,
  plain when unsupported), f.picture(Placement)->bool (false = no kitty), f.link(rect,url) (OSC 8), f.hit(rect,action), f.header(body_need,pic_rows)
Sizing::scale(n) | Sizing::frac(scale,num,den) {valign 0 top/1 bottom/2 centre}  Style::new().fg().bg().bold().italic().dim().strike()
  .underline(Underline::{Single,Double,Curly,Dotted,Dashed}).ul_color(Rgb)  // strike = SGR 9
Placement::new(&pic,col,row) /*z -1*/ .at_px(x,y,cw,ch) .pid(n) .z(i) .crop(Crop)  Same (pic.id,pid) next frame = moved in place; omitted = deleted.
  A still keeps its data when its placement goes. A clip keeps its data too (frames and all) until more than MAX_LIVE_CLIPS (3) are kept: then the
  one placed least recently, and not on screen, is deleted (`a=d,d=I`); a clip that returns is placed again, never sent again.
Picture::new(w,h,rgba) .id() .width() .height() .rgba() .upload() /*pre-encoded transmit payload, Some for decoded files*/ .cells(cw,ch);
  Picture::animated(w,h,rgba,first_gap_ms,Vec<Cel{gap_ms,rgba,encoded}>) .is_animated() .gap_ms() .cel_count() /*frames after the first, arrived so far*/
  .with_cel(i,|c|..) .complete(); Picture::from_decoded(Decoded{w,h,rgba,upload,clip:Option<Receiver<apng::Msg>>,plain})
picture::decode_file(&FileKey)->io::Result<Decoded> /*any thread: decode, fit, card, encode; a clip's other frames from a worker thread*/;
  FileKey = (PathBuf, box_w, box_h, Fit, Option<Rgb> card, animate); Pictures::key(path,w,h,fit,card,animate), pics.header_key(path,w,h,animate)
ctx.pics: .script_word(text,px_h,Rgb) /*Pinyon*/ .mark(px,Rgb) .lookup(&key)->Lookup::{Have(Picture),Failed,Missing} .insert_decoded(key,Decoded)->Picture
  .note_failed(key) .file(path,w,h,Fit) .header_picture(path,w,h,animate) /*both decode on the calling thread: tests, fallbacks*/ .shape(key, ||(w,h,rgba));
  Fit::Width fills the width, keeps the busiest band, framed as a card (rounded, `card_edge` hairline); animate + APNG = a clip: frame 1 now, the rest
  fitted+encoded by a worker thread (picture::apng), thinned to ≤32 MB / ≤48 frames by dropping every other frame (gaps folded) until it fits;
  MAX_CLIPS (3) clips cached at a time, oldest out. picture::shapes::{fade_bottom, pill(w,h,r,Rgb,alpha), progress_line(w,h,line_h,pct,track,fill)}
picture::apng: Apng::open(&bytes)->Option<Apng> (acTL) .size() .frames() .next_frame()->Option<Cel> (full canvas; dispose NONE/BACKGROUND/PREVIOUS,
  blend SOURCE/OVER); stride(frames,frame_bytes); thin(cels,stride); stream(bytes,w,h,fit,card,stride,encode,&tx) /*Msg::StillGap then Msg::Frame;
  encode: Cel.encoded = zlib level 1 + base64, rgba empty*/
render::escapes: encode_payload(data,level)->String /*zlib+base64, what o=z carries*/, STILL_ZLIB_LEVEL 6, FRAME_ZLIB_LEVEL 1,
  kitty_transmit[_encoded], kitty_frame[_encoded], kitty_place, kitty_delete_placement, kitty_delete_image, kitty_animate
Renderer: render(buf,places,out) diffs (a pre-encoded picture is only chunked); pending() while a clip on screen has frames to send; stream(out) sends
  one `a=f` frame (i, f=32, s, v, X=1, z=gap ms, o=z, chunked m=) per call, then `a=a,i,r=1,z=<frame 1 gap>,s=3,v=1` to loop; the app loop calls it
  between events at STREAM_PACE (one frame per 60 fps tick) once the bytes before it have left. The launcher's KittyGraphicsProtocol accepts a=f
  (i,s,v,x,y,z,c,r,X,Y,o,m,q) and a=a (r+z, c, s, v); frame quota RAM/48 clamped 64–256 MB, folded rather than refused; frames die with the session.
app loop: frames and clip frames go into a write queue; the owned /dev/tty is non-blocking and takes what fits (TermIo::write_some), the rest waits for
  POLLOUT in the same poll as input, signals and watched fds (TermIo::out_fd); flushed whole before the terminal is restored.

layout: BASE 53×26. tier(cols,rows)->Tier::{Tall ≥40, Base 26–39, Compact <26}; narrow(cols)=cols<44; gutter 2 (1 narrow); item_rows(tier)=3|1
header(cols,rows,body_need,pic_rows:Option<u16>) -> Header { tier, narrow, gutter, cols, rows, content, masthead:0, picture:Option<Rect>,
  name:Rect(3 rows, 2 Compact), standfirst, facts, body:Rect, notice:rows-2, keys:rows-1 }
  Rows: masthead, blank, [picture P, blank], name, standfirst, facts, blank, body, notice, keys. P = rows − 11 − body_need, ≤12, ≤pic_rows
  (the picture's own rows; u16::MAX = reserve), 0 under 4 or when pic_rows is None; Compact never. 53×26 Front: P 8 over 7 rows; 53×40: P 9 over 20.
Key row: key_label_gap(label) = 2 after a glyph (non-ASCII) label, 1 after letters; key_words_room(cols,&[(label+gap, words_w)]) cuts
  words (`…`, ≥1 column) from the rightmost-longest until the shown items fit with KEY_MIN_GAP 2; key_starts(cols,&widths) justifies them:
  first at the gutter, last ending at the right gutter, equal gaps (remainder to the leftmost).
wrap(s,w,max_lines)/fit_line(s,w): whole words, `…` when cut. centre_x(rect,w).

use tlstore_ui::store::{Router, Store, Go, View, Verb, Job, Gh, Got, Readme, SelfUpdate, Exit, GH_NOTICE, STORE_REPO, SELF_UPDATE_HOLD, UPDATED_NOTICE,
  header_for, picture_in, paint::*, scene::*, readme, motion::Timeline};
Router::new(env) (no motion) | Router::animated(env) (Timeline) | Router::with_motion(env, Box<dyn Motion>); Router::set_clock(Fn()->Instant)
Router is the only app::Screen; views: Front → Item → Installing, stacked; Router::top()/depth()/header_item(); router.st is the Store.
trait View { name()->"front"|"item"|"installing"; draw(&mut self,p:&mut Paint,st:&mut Store) /*header + body*/; keys(&self,st)->Slots;
  handle(&mut self,ev,st)->Go::{Stay,Pass,Push,Replace,Back,Home,Quit}; refresh(&mut self,st) }  Router draws notice + key row after draw().
Job{verb,names,current /*owner of the live row*/,pct /*whole job, never lower*/,rows: Vec<Row>,step,done,exit,cancelled,errors: Vec<String>}; Row{name,action,kind,by,why,
  pct,words,state: RowState::{Pending,Live,Done{ok,message}}} — data::Progress::Row from `row\tname\taction\tkind\tversion\tby\twhy` (Revision 17).
  `error\ttext` (data::Progress::Error; two fields, no final period, any point of the stream: before a row, between, after the last done) → Job.errors, in order; unknown kinds stay ignored.
  Job::new seeds an implied row per name (dropped by the first `row` line); a `step` for an unknown name appends one (by requested|auto, kind -);
  step: row.pct=max, Live, current=owner(row) (requested → itself; `needed by X`/`part of X` → X, up the plan; else names[0]); done ok: row 100, failed: row stays.
  pct = max(pct, Σw·row.pct/Σw), w by kind for install (pkg 3; binary/archive/npm-* 4; fisher 2; file/file-once 1; bundle 0; other 2),
  remove/forget/absent/retire 1, skip/unavailable 0, all 0 → 1; 100 at exit when every done is ok. owner(row), live(), word_for(name).
Store: cat (Catalog: items, updates, info(name)->&Info, loading, error), job: Option<Job>, gh, stars,
  notice, notice_until (a timed notice; any key clears both), now (router clock), start_job/cancel_job/job_running, star(name)->bool (GH_NOTICE on
  the notice row when gh is signed out; waits for gh while it is still being asked), open_url/open_repo, toggle_fullscreen (launcherctl as a task,
  optimistic), facts(name,state)->Facts, self_update: SelfUpdate::{Checking,NotOffered,Offered{have,new}}, quit_at, exit: Rc<RefCell<Option<Exit>>>,
  fetch(Fetch)->Got::{Pending,Ready(path),Failed(code)} (spawns `tlstore picture|readme|readme-asset` once, off the draw path; while the prefetch runs a
  picture/demo/readme is awaited from it instead), picture(&mut pics, FileKey)->Lookup (the decode worker fits it; Missing until then),
  picture_path(name), readme(name)->Readme::{Loading /*fetching or being parsed by the worker*/,Doc(Rc<Doc>),NoUpstream /*exit 2*/,Unavailable /*exit 1*/},
  asset_path(name,src), header_shown(name)/header_rested(name,motion) /*150 ms rest, wake_at ticks the router*/, tasks_pending() /*tasks or decodes*/,
  take_job_finished(), leaving.
  Nothing runs synchronously: Store::new spawns `tlstore self-update --check --tsv` first, then `tlstore snapshot --tsv` (Catalog::loading until it
  lands; Front says Loading…), `update --check --tsv` (which no longer touches tlstore itself) and `gh auth status`. Jobs run
  `tlstore <Verb::arg> --progress <names>`: install, upgrade (Verb::Update; `update` only lists since tlstore 0.21), remove, self-update. The check (data::parse_self_check:
  `self\t<have>\t<new>\t<0|1>`) answering available only records SelfUpdate::Offered{have,new}: nothing starts by itself. Front's notice row then shows
  `● tlstore <new> is out · U to update` (● accent, the words dim italic) while no job runs and nothing else is on the row (a notice or the selection
  bar wins; a channel problem too; the hint returns after). Narrow: "is out" goes first (`● tlstore <new> · U to update`), then the name
  (`● U to update`), then the dot; `U to update` stays. `U` (Key::Char('U')) or a tap on the hint (paint::A_SELF 6, hit rect over the hint)
  calls Store::start_self_update (Offered and no job): Verb::SelfUpdate (`tlstore self-update --progress`, names ["tlstore"], not held for
  the refresh), and Front pushes Installing. `U` with nothing offered does nothing; `u` (upgrade) is unchanged. Item and Installing show no hint.
  Anything else, and startup is as before. The snapshot's readme: Verb::SelfUpdate
  never takes a snapshot or sends an OSC 99. Env.self_updated ($TLSTORE_UI_SELF_UPDATED=<version>, set by the re-exec below) skips the check and puts
  "tlstore updated to <version>" on the notice row for UPDATED_NOTICE (4 s).
  The snapshot (data::Snapshot::parse: item/field/update/cached lines) fills the catalog and seeds fetched with every cached
  asset and every asset an item does not have (Failed at once); then `tlstore prefetch` runs once (again after a refresh), its lines
  (proc::parse_prefetch: ready/failed name kind path|reason [src]) landing in fetched as they arrive; a job's end and a refresh ask for a new snapshot.
  on_readable(fd, &mut pics) also drains the decode worker (store::decode: 2 threads, a self-pipe fd in watch() while busy).
header_for(p, st, name, body_need, readme_first, reserve, animate) -> (Header, Option<Picture>)  // fitted picture, placed only once rested; nothing
  is fetched or decoded before the rest; rows reserved (u16::MAX) while a fetch or a decode is on its way; animate && ctx.motion: an APNG plays
  (Front after the 150 ms rest, Item); Installing passes false. TLSTORE_MOTION=0 or --shot: frame 1 only.
picture_in(st, pics, path, box_w, box_h) -> Lookup  // a README picture, contain-fitted by the worker
paint: Paint{f,fx,scene,clip,scroll}: text/text_clip/right/centred/fill/hline/sized/picture(el,pic,col,row,(off_x,off_y),pid)/hit/link; alpha fades
  toward the surface, pictures hide under 0.5. draw_header(p,&Header,&HeaderContent{masthead: Masthead::{Front{updates,filter},Page{repo,setup}},
  picture, name, standfirst, facts: Facts{state,version,new,more}}); draw_keys(p,&Header,&Slots) /*[Option<Slot{label,words,key,on}>;5]; None not shown, off dim in place*/;
  draw_notice(p,&Header,text). Taps: A_HOME 1, A_BACK 2, A_CONTEXT 3 (updates / repo), A_ALL 4, A_HEADER 5, A_SELF 6 (Front: the tlstore hint), A_KEY0+i 10..14; screens use 100+.
readme: parse(md, skip:&[String]) -> Doc{first_image, blocks: Vec<Block>} (drop rules of REVISION-6.md; SKIP_SECTIONS + skip, case-insensitive);
  fit(&Doc, width, repo_url) -> Vec<Row::{Blank, Text{indent,spans,quote}, H2, H3, Code, Image{src,alt}, Hairline, Link{text,url}}>;
  MAX_ROWS 400, CODE_LINES 12, IMAGE_ROWS 6; image_kind(src)->{Inline,Skip,Gif}; wrap_spans(spans,width). Item paints rows lazily (assets on view).
scene: El::{Mark, Context, Picture, Name, Standfirst, Facts, Pill, Row(n), Block(n), Pager, Keys, Notice}; El::is_body() = Pill|Row|Block|Pager.
  Scene{screen, elements: Vec<Element{el,rect,picture:Option<(img,pid)>,text}>, cell}; Scene::body() in drawing order. Effect{alpha, value}.
  trait Motion { navigate(kind:NavKind,from:&Scene,to,now); frame(now,&Scene)->Phase::{Idle,Leaving(Fx),Entering(Fx)}; active(); drawn(now,&Scene)->bool }
motion (D7): leave 120 ms body fade (pictures hidden at once); enter: body element i fades 0→1 over 200 ms from min(30·i,100) ms, rest by 300;
  header/notice/keys never move; Installing count-up 200+6·|Δ| ms (≤700) on Block(0).value (targets only grow: it never counts down).
  Input goes to the new view at once, during the leave too. TLSTORE_MOTION=0: no navigate/frame/drawn, frames at rest, header pictures placed at once.
Installing: number + bar = job.pct (100 when all ok); Block(1..4) at gutter+12, rows b..b+3: the plan, `<name>  <words>` — pending rule (its `fetched` dim when the fetch phase got it), live accent
  + dotted words, done dim `ready` (or the message unless installed/updated), failed ink bold + reason; 4-line window, live on line min(i,2);
  first four before any step, last four after; summary once over (a job with no failed row, or a cancelled one: unchanged). Row b+6 `then <queued>`; no "also bringing". The header: shown_name().
  Job.errors: the first error replaces the `then` row (same row, ink bold = failed ink), later ones follow on b+7.. while the body has room (wrapped at b.w; never over the notice/key rows);
  they stay when the job is over. Done and not cancelled and ≥1 failed row (not SelfUpdate): instead of the summary, one block of `<name>  <reason>` per failed row, then each error, then dim `N ready`
  (N = rows done ok, omitted at 0): wrapped (never cut) at the name column's width beside the number when ≤4 lines (rows b..b+3), else at b.w under the progress line from b+6;
  too long → the earliest lines are dropped, the fold line never. Block(1..4) / Block(6..) fade in as other body elements. Summary sentence (Job::summary, the notice): `Could not <verb> <items>: <reason>.`
  reason = the first `error` else the first failed item's own done message (trailing `.` dropped; none → `Could not <verb> <items>.`); several: `a and b`; SelfUpdate and the GitHub notice keep `Try again later.`
  Keys once over: `⏎ done` · `d details` (Job::failed_for_details: over, not cancelled, a row or error failed) · `esc back`.
Notice: Store.failure_notice marks the failure notice (set where the router puts a job's summary on the row; cleared by the next key/tap). paint::draw_notice is one line, as ever; while the failure notice shows
  the router uses draw_notice_wrapped: one line when it fits, else two (word wrap into hdr.notice-1 and hdr.notice, both rows cleared across the content width first; the body is not re-laid out, its last row is covered).
  `d details` then sits in key slot 3 on Front (in place of `select`, so 40 columns still fit) and Item (in place of `o repo`); the router takes that `d` itself (the key that clears the notice) and pushes Details.
Details (view name "details", store/details.rs): the transcript `<Store.home>/.cache/tlstore/last-job.log` (Store.home = Ctx.home, copied in by the router each draw/handle) as plain wrapped lines under the header
  of Job::shown_name (facts `failed`), scrolling as the item page (↑↓/j/k, PageUp/PageDown, Home/End, wheel, drag). A first line `To fix:` + the command on the next line (then a blank) is drawn `To fix:` accent bold and the command
  in the tonal code style; the rest ink. Missing or empty file: one dim line `No transcript from the last job.` Keys: `c copy` (only with a `To fix:` head) · `esc back` (Back/←/backspace too).
  `c`: Env.copy(command) — `termux-clipboard-set` (Env.clipboard: `$TLSTORE_CLIPBOARD`, else PATH) with the command on stdin, else OSC 52 `ESC ] 52 ; c ; <base64> BEL` through Env.tty_write — then notice `copied`.
Installing, Verb::SelfUpdate: the same screen for the item `tlstore` — no catalog row and no picture (layout::header(…,7,None)), the name in the script
  face, standfirst "the launcher's tool store", masthead link STORE_REPO, facts `updating <have> → <new>` from Store::self_update; steps and the line
  from the stream as for any item (fetched to 80, signature checked 85, putting files in place 92, ready 100). Keys while running: `x cancel` · `esc
  back`; esc/back, x and q all cancel (a self-update never runs on under the store), esc then goes Back and q quits. `done tlstore ok`: Store sets
  quit_at = now + SELF_UPDATE_HOLD (600 ms) and exit = Exit::ReExec{version} (from "updated to <v>", else the check's new); the screen holds at 100
  and ignores keys, Router::animating stays true, Router::finished turns true at quit_at and app::run ends as on a quit (outq flushed, Tty dropped:
  LEAVE — modes off, kitty images deleted, cursor shown, main screen — then Router::drop). main then execs the path current_exe() gave at startup
  (the file was replaced by rename; /proc/self/exe is stale by then) with the same argv and env plus TLSTORE_UI_SELF_UPDATED=<version>; a failed
  exec prints "tlstore updated to <v> — run tlstore again" and exits 0. `done tlstore failed`: the failure summary as for any job (notice row
  "Could not update tlstore. Try again later."), ⏎ done → Back, the store goes on on the old files.
Measured (tests/screens.rs, 53×26 kitty, push to item): frames ≤ 8 KB, nothing written at rest. Release binary (host x86_64, stripped): 1.41 MB.
Binary: tlstore-ui | --probe | --version; env TLSTORE_UI_SELF_UPDATED=<version> (set only by the re-exec above). Fixture store: tests/fixtures/store
  (stub tlstore speaks snapshot/prefetch/list/info/update/upgrade/self-update/picture/readme/readme-asset/jobs; `picture` answers pics/<name>.png before
  .jpg, so a test can drop in an APNG; `prefetch` reports every fixture asset only when the file prefetch-lines exists (Opts.prefetch), else
  nothing, so every asset is asked for on its own; `self-update --check` offers 0.6 → 0.7 only when the file self-update exists (Opts.self_update),
  `self-update --progress` plays the tlstore stream, sleeping at 44 with `hold`, failing with `fail-tlstore`; Opts.self_updated sets Env.self_updated;
  install/upgrade/remove --progress print a `row` per name first (binary, requested, -), then per name 10 [60 + sleep with `hold`] 60 90 100 done
  (`broken`/fail-<n> fail); `part-<name>` holding a part's name announces it first (`pkg`, auto, `needed by <name>`) and runs it 10→100, done ok).

# preview renderer (cargo feature `shot`; dev only, build-ui.sh never enables it)
tlstore-ui --shot <cols>x<rows> --screen <spec> --out <file.png> [--store <dir>]  |  --shot-all --out <dir> [--store <dir>]
  <spec>: front[:cursor] · front:selected=<a,b> · front:updates · item:<name>[:scroll] · installing:<name>:<pct>; --store defaults to
  tests/fixtures/store (copied to a temp dir, pictures from scripts/pictures, gh signed in). --shot-all: front, item:dawn,
  installing:dawn:64 at 53×26, 53×40, 40×24 as <slug>-<cols>x<rows>.png.
Drives the real Router (Caps::all(), motion off, 12×26 px cells), settles every task (snapshot, prefetch, refresh, gh, picture, readme, assets,
  decodes) like tests/screens.rs, and paints the resting frame: surface, cell backgrounds, placements z<0, glyphs from bundled JetBrains Mono
  (assets/fonts/jetbrainsmono, OFL) with bold/italic/dim/reverse, underline styles + colour, strike, OSC 66 runs at scale×num/den
  with their alignment, then placements z≥0 with their alpha. ★/☆ drawn by hand; other missing glyphs are boxes.
shot::{Spec::parse, render(cols,rows,&Spec,store)->Image{width,height,rgba,pixel(),png()}, shoot(..,&Path), shoot_all(dir,store), cli(args)}
  installing:<name>:<pct> uses Store::fake_job(verb,name,pct) + Router::show_installing() (both cfg(feature="shot"); no script runs).
Test: tests/shot.rs (`cargo test --features shot`): front 53×26 is a PNG with ink on the name rows.
