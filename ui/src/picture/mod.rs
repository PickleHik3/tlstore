//! Pictures: RGBA bitmaps the renderer uploads to the terminal once and places by id.
//! Four sources: script words set in the bundled Pinyon Script face, the pixel TLSTORE mark,
//! JPEG/PNG files from disk (catalog and README pictures; an APNG header picture is a clip,
//! see [`apng`]), and the shapes the store draws itself ([`shapes`]).
//!
//! A file is decoded by [`decode_file`], which any thread may run (the store's decode worker
//! does, so a draw never waits on one); the result ([`Decoded`]) is plain data that the UI
//! thread turns into a [`Picture`] and puts in the cache ([`Pictures::insert_decoded`]).

pub mod apng;
pub mod file;
pub mod mark;
pub mod script;
pub mod shapes;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};

use crate::render::escapes::{encode_payload, STILL_ZLIB_LEVEL};
use crate::render::Rgb;

pub use apng::Cel;
pub use file::Fit;

/// How much of a header picture fades out along its bottom edge.
pub const HEADER_FADE: f32 = 0.38;

/// How many clips (animated pictures, frames and all) the cache keeps at once; the oldest
/// goes when another arrives. Three covers the item under the cursor, the one opened and
/// the one before it, so going back re-places a clip instead of decoding it again.
pub const MAX_CLIPS: usize = 3;

/// The frames after the first of an animated picture, arriving from the frame worker.
struct Clip {
    /// How long the first frame (the picture itself) shows, once known.
    first_gap: Cell<u32>,
    cels: RefCell<Vec<Cel>>,
    /// The worker's channel; `None` once every frame is here.
    rx: RefCell<Option<Receiver<apng::Msg>>>,
}

struct PicData {
    id: u32,
    w: u32,
    h: u32,
    rgba: Vec<u8>,
    /// The transmit payload (zlib + base64), encoded by the thread that decoded the file.
    upload: Option<String>,
    clip: Option<Clip>,
}

/// A shared, immutable RGBA picture (straight alpha, row-major). Cloning is cheap. Each new
/// picture gets a fresh kitty image id. An animated picture is its first frame plus the
/// frames after it ([`Picture::cel_count`]), which may still be arriving.
#[derive(Clone)]
pub struct Picture(Rc<PicData>);

impl std::fmt::Debug for Picture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Picture#{}({}x{})", self.0.id, self.0.w, self.0.h)?;
        if self.is_animated() {
            write!(f, "+{}", self.cel_count())?;
        }
        Ok(())
    }
}

/// Kitty image ids are shared by everything in the terminal; start high to stay clear of
/// other programs' small ids.
static NEXT_ID: AtomicU32 = AtomicU32::new(0x7153_0001);

/// A decoded file, as any thread can produce it: the first frame fitted (and framed), its
/// transmit payload already encoded, and, for a clip, the channel its other frames arrive
/// on. `plain` says a file asked for as a clip turned out to be an ordinary picture.
pub struct Decoded {
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
    pub upload: Option<String>,
    pub clip: Option<Receiver<apng::Msg>>,
    pub plain: bool,
}

impl Picture {
    /// Wraps `rgba` (length must be `w * h * 4`).
    pub fn new(w: u32, h: u32, rgba: Vec<u8>) -> Picture {
        Picture::with_clip(w, h, rgba, None, None)
    }

    /// An animated picture whose frames are all here: `rgba` shows for `first_gap_ms`, then
    /// each of `cels` (every one `w * h * 4` bytes, or encoded) for its own gap, round and round.
    pub fn animated(w: u32, h: u32, rgba: Vec<u8>, first_gap_ms: u32, cels: Vec<Cel>) -> Picture {
        for c in &cels {
            assert!(
                c.rgba.len() == w as usize * h as usize * 4 || (c.rgba.is_empty() && c.encoded.is_some()),
                "cel length"
            );
        }
        let clip = Clip {
            first_gap: Cell::new(first_gap_ms),
            cels: RefCell::new(cels),
            rx: RefCell::new(None),
        };
        Picture::with_clip(w, h, rgba, None, Some(clip))
    }

    /// A picture from what a decoder produced (a clip when frames follow on its channel).
    pub fn from_decoded(d: Decoded) -> Picture {
        let clip = d.clip.map(|rx| Clip {
            first_gap: Cell::new(apng::DEFAULT_GAP_MS),
            cels: RefCell::new(Vec::new()),
            rx: RefCell::new(Some(rx)),
        });
        Picture::with_clip(d.w, d.h, d.rgba, d.upload, clip)
    }

    fn with_clip(w: u32, h: u32, rgba: Vec<u8>, upload: Option<String>, clip: Option<Clip>) -> Picture {
        assert_eq!(rgba.len(), w as usize * h as usize * 4, "rgba length");
        Picture(Rc::new(PicData { id: NEXT_ID.fetch_add(1, Ordering::Relaxed), w, h, rgba, upload, clip }))
    }

    pub fn id(&self) -> u32 {
        self.0.id
    }
    pub fn width(&self) -> u32 {
        self.0.w
    }
    pub fn height(&self) -> u32 {
        self.0.h
    }
    pub fn rgba(&self) -> &[u8] {
        &self.0.rgba
    }
    /// The transmit payload when it was encoded ahead of time (a decoded file).
    pub fn upload(&self) -> Option<&str> {
        self.0.upload.as_deref()
    }
    /// Cells needed to show it at natural size on a `cell_w`×`cell_h` grid (rounded up).
    pub fn cells(&self, cell_w: u16, cell_h: u16) -> (u16, u16) {
        let cw = cell_w.max(1) as u32;
        let ch = cell_h.max(1) as u32;
        (self.0.w.div_ceil(cw) as u16, self.0.h.div_ceil(ch) as u16)
    }

    /// True for a picture with frames after the first (arrived or still coming).
    pub fn is_animated(&self) -> bool {
        self.0.clip.is_some()
    }

    /// Takes what the frame worker has sent so far.
    fn drain(&self) {
        let Some(clip) = &self.0.clip else { return };
        let done = {
            let rx = clip.rx.borrow();
            let Some(r) = rx.as_ref() else { return };
            loop {
                match r.try_recv() {
                    Ok(apng::Msg::StillGap(g)) => clip.first_gap.set(g),
                    // A frame of another size would be a bug in the worker; it is not shown.
                    Ok(apng::Msg::Frame(c)) => {
                        if c.rgba.len() == self.0.rgba.len() || (c.rgba.is_empty() && c.encoded.is_some()) {
                            clip.cels.borrow_mut().push(c);
                        }
                    }
                    Err(TryRecvError::Empty) => break false,
                    Err(TryRecvError::Disconnected) => break true,
                }
            }
        };
        if done {
            *clip.rx.borrow_mut() = None;
        }
    }

    /// How long the first frame shows, in milliseconds (an animated picture; else 0).
    pub fn gap_ms(&self) -> u32 {
        self.drain();
        self.0.clip.as_ref().map_or(0, |c| c.first_gap.get())
    }

    /// Frames after the first that have arrived so far.
    pub fn cel_count(&self) -> usize {
        self.drain();
        self.0.clip.as_ref().map_or(0, |c| c.cels.borrow().len())
    }

    /// Reads frame `i` (0 = the first frame after the still) when it has arrived.
    pub fn with_cel<R>(&self, i: usize, f: impl FnOnce(&Cel) -> R) -> Option<R> {
        self.drain();
        let clip = self.0.clip.as_ref()?;
        let cels = clip.cels.borrow();
        cels.get(i).map(f)
    }

    /// True once every frame is here (always, for a still).
    pub fn complete(&self) -> bool {
        self.drain();
        self.0.clip.as_ref().is_none_or(|c| c.rx.borrow().is_none())
    }
}

/// A fitted file's cache key: path, box width and height, fit, card edge, animated.
pub type FileKey = (PathBuf, u32, u32, Fit, Option<Rgb>, bool);

/// What the cache knows about a file key.
pub enum Lookup {
    Have(Picture),
    /// Decoding it failed once already; it is not tried again.
    Failed,
    Missing,
}

/// Caches every picture a run makes, so a word, file or shape is made once and keeps its
/// kitty id (and so is uploaded once). Up to [`MAX_CLIPS`] clips are kept at a time: the
/// oldest goes, frames and all, when another arrives.
#[derive(Default)]
pub struct Pictures {
    face: Option<fontdue::Font>,
    words: HashMap<(String, u32, Rgb), Picture>,
    marks: HashMap<(u32, Rgb), Picture>,
    /// By path, box, fit, card edge and whether the frames were wanted.
    files: HashMap<FileKey, Picture>,
    /// The clip keys in `files`, oldest first.
    clips: VecDeque<FileKey>,
    /// Files asked for as clips that turned out to be plain pictures.
    plain: HashSet<PathBuf>,
    /// Keys whose decode failed (a worker said so).
    failed: HashSet<FileKey>,
    shapes: HashMap<String, Picture>,
    /// The hairline colour header pictures are framed in (the palette's `rule`).
    pub card_edge: Rgb,
}

impl Pictures {
    pub fn new() -> Pictures {
        Pictures::default()
    }

    /// `text` set in Pinyon Script, exactly `px_h` pixels tall (ascender to descender),
    /// in `color` on transparent. Cached.
    pub fn script_word(&mut self, text: &str, px_h: u32, color: Rgb) -> Picture {
        let key = (text.to_string(), px_h, color);
        if let Some(p) = self.words.get(&key) {
            return p.clone();
        }
        let face = self.face.get_or_insert_with(script::load_face);
        let (w, h, rgba) = script::rasterise(face, text, px_h, color);
        let p = Picture::new(w, h, rgba);
        self.words.insert(key, p.clone());
        p
    }

    /// The TLSTORE pixel mark, each mark pixel a `px`×`px` block. Cached.
    pub fn mark(&mut self, px: u32, color: Rgb) -> Picture {
        self.marks
            .entry((px, color))
            .or_insert_with(|| {
                let (w, h, rgba) = mark::render(px, color);
                Picture::new(w, h, rgba)
            })
            .clone()
    }

    /// The cache key for a file scaled into a box (see [`Fit`]); `card` frames it as a card.
    pub fn key(path: &Path, box_w: u32, box_h: u32, fit: Fit, card: Option<Rgb>, animate: bool) -> FileKey {
        (path.to_path_buf(), box_w, box_h, fit, card, animate)
    }

    /// The key of a header picture: width-fitted, framed in [`Pictures::card_edge`].
    pub fn header_key(&self, path: &Path, box_w: u32, box_h: u32, animate: bool) -> FileKey {
        Pictures::key(path, box_w, box_h, Fit::Width, Some(self.card_edge), animate)
    }

    /// The key as the cache stores it: a file known to be plain is kept under the plain key,
    /// whether or not frames were asked for.
    fn stored_key(&self, key: &FileKey) -> FileKey {
        if key.5 && self.plain.contains(&key.0) {
            (key.0.clone(), key.1, key.2, key.3, key.4, false)
        } else {
            key.clone()
        }
    }

    /// What is known for `key` without decoding anything.
    pub fn lookup(&self, key: &FileKey) -> Lookup {
        let k = self.stored_key(key);
        if let Some(p) = self.files.get(&k) {
            return Lookup::Have(p.clone());
        }
        if self.failed.contains(&k) {
            return Lookup::Failed;
        }
        Lookup::Missing
    }

    /// Puts a decoded file in the cache under `key` (or the plain key when it turned out
    /// plain) and hands back its picture.
    pub fn insert_decoded(&mut self, key: FileKey, d: Decoded) -> Picture {
        let mut key = key;
        if d.plain {
            self.plain.insert(key.0.clone());
            key.5 = false;
            // The still may be here already (the probe): keep it, and its kitty id.
            if let Some(p) = self.files.get(&key) {
                return p.clone();
            }
        }
        let animated = d.clip.is_some();
        let p = Picture::from_decoded(d);
        if animated {
            self.clips.push_back(key.clone());
            while self.clips.len() > MAX_CLIPS {
                if let Some(old) = self.clips.pop_front() {
                    self.files.remove(&old);
                }
            }
        }
        self.files.insert(key, p.clone());
        p
    }

    /// Notes that decoding `key` failed, so nobody asks again this run.
    pub fn note_failed(&mut self, key: FileKey) {
        self.failed.insert(key);
    }

    /// A JPEG or PNG file scaled into a `box_w`×`box_h` pixel box (see [`Fit`]). Cached by
    /// path and box. Decodes here, on the calling thread.
    pub fn file(&mut self, path: &Path, box_w: u32, box_h: u32, fit: Fit) -> io::Result<Picture> {
        self.file_with(path, box_w, box_h, fit, None, false)
    }

    /// A header picture: fitted to the box's width (its bottom cropped when taller) and framed
    /// as a card — rounded corners and a hairline border in [`Pictures::card_edge`]. With `animate`, an APNG file comes back as a clip: the first frame now,
    /// the frames after it fitted and faded the same way by a worker thread, thinned to
    /// [`apng::MAX_CLIP_BYTES`] / [`apng::MAX_CLIP_FRAMES`]. Cached by path, box and `animate`.
    /// Decodes here, on the calling thread.
    pub fn header_picture(
        &mut self,
        path: &Path,
        box_w: u32,
        box_h: u32,
        animate: bool,
    ) -> io::Result<Picture> {
        self.file_with(path, box_w, box_h, Fit::Width, Some(self.card_edge), animate)
    }

    fn file_with(
        &mut self,
        path: &Path,
        box_w: u32,
        box_h: u32,
        fit: Fit,
        card: Option<Rgb>,
        animate: bool,
    ) -> io::Result<Picture> {
        let key = self.stored_key(&Pictures::key(path, box_w, box_h, fit, card, animate));
        if let Some(p) = self.files.get(&key) {
            return Ok(p.clone());
        }
        let d = decode_file(&key)?;
        Ok(self.insert_decoded(key, d))
    }

    /// A drawn shape, made by `make` the first time `key` is asked for. Cached by key, so the
    /// same shape keeps its id and is uploaded once.
    pub fn shape(&mut self, key: String, make: impl FnOnce() -> (u32, u32, Vec<u8>)) -> Picture {
        self.shapes
            .entry(key)
            .or_insert_with(|| {
                let (w, h, rgba) = make();
                Picture::new(w, h, rgba)
            })
            .clone()
    }

    /// Drops every cached picture (their terminal copies are freed by `Renderer::forget` or
    /// on exit).
    pub fn clear(&mut self) {
        self.words.clear();
        self.marks.clear();
        self.files.clear();
        self.clips.clear();
        self.plain.clear();
        self.failed.clear();
        self.shapes.clear();
    }
}

/// Decodes the file `key` names and fits it into the key's box: a still, or, when frames
/// were asked for and the file is an APNG, a clip whose other frames a worker thread fits
/// from its own copy of the bytes. Runs on any thread; the upload payload is encoded here
/// too, so the UI thread only chunks it.
pub fn decode_file(key: &FileKey) -> io::Result<Decoded> {
    let (path, box_w, box_h, fit, card, animate) = key;
    let bytes = std::fs::read(path)?;
    if *animate {
        if let Some(a) = apng::Apng::open(&bytes)? {
            return clip(a, &bytes, *box_w, *box_h, *fit, *card);
        }
        let mut d = still(&bytes, *box_w, *box_h, *fit, *card)?;
        d.plain = true;
        return Ok(d);
    }
    still(&bytes, *box_w, *box_h, *fit, *card)
}

fn still(bytes: &[u8], box_w: u32, box_h: u32, fit: Fit, card: Option<Rgb>) -> io::Result<Decoded> {
    let (sw, sh, src) = file::decode(bytes)?;
    let (w, h, rgba) = file::fit_into(sw, sh, &src, box_w, box_h, fit);
    Ok(finish(w, h, rgba, card, None))
}

/// Frames the picture as a card when asked, encodes its payload, and packs it up.
fn finish(w: u32, h: u32, mut rgba: Vec<u8>, card: Option<Rgb>, clip: Option<Receiver<apng::Msg>>) -> Decoded {
    if let Some(edge) = card {
        shapes::card(w, h, &mut rgba, shapes::card_radius(w, h), edge);
    }
    let upload = Some(encode_payload(&rgba, STILL_ZLIB_LEVEL));
    Decoded { w, h, rgba, upload, clip, plain: false }
}

/// The first frame of `apng`, fitted and faded, whose other frames a worker thread fits from
/// its own copy of `bytes`; a plain picture when the guard leaves the still alone or the
/// worker cannot start.
fn clip(
    mut apng: apng::Apng<'_>,
    bytes: &[u8],
    box_w: u32,
    box_h: u32,
    fit: Fit,
    card: Option<Rgb>,
) -> io::Result<Decoded> {
    let (sw, sh) = apng.size();
    let frames = apng.frames() as usize;
    let first = apng
        .next_frame()?
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "APNG without frames"))?;
    drop(apng);
    let (w, h, rgba) = file::fit_into(sw, sh, &first.rgba, box_w, box_h, fit);
    let stride = apng::stride(frames, rgba.len());
    if frames.div_ceil(stride) <= 1 {
        return Ok(finish(w, h, rgba, card, None));
    }
    let (tx, rx) = mpsc::channel();
    let owned = bytes.to_vec();
    let spawned = std::thread::Builder::new()
        .name("tlstore-hero".into())
        .spawn(move || apng::stream(&owned, box_w, box_h, fit, card, stride, true, &tx));
    Ok(finish(w, h, rgba, card, spawned.ok().map(|_| rx)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_complete(p: &Picture) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !p.complete() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(p.complete(), "the frame worker did not finish");
    }

    #[test]
    fn an_apng_header_picture_is_a_clip_and_a_plain_png_is_not() {
        let dir = std::env::temp_dir().join(format!("tlstore-ui-clip-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hero.png");
        std::fs::write(&path, apng::tests::tiny_apng()).unwrap();
        let mut pics = Pictures::new();
        let still = pics.header_picture(&path, 4, 4, false).unwrap();
        assert!(!still.is_animated() && still.complete());
        assert_eq!((still.cel_count(), still.gap_ms()), (0, 0));
        assert!(still.upload().is_some(), "the payload is encoded with the decode");
        let clip = pics.header_picture(&path, 4, 4, true).unwrap();
        assert!(clip.is_animated());
        assert_ne!(clip.id(), still.id());
        assert_eq!((clip.width(), clip.height()), (4, 4));
        assert_eq!(&clip.rgba()[..4], &[255, 0, 0, 255], "the still is the first frame");
        wait_complete(&clip);
        assert_eq!(clip.cel_count(), 3, "the frames after the still");
        assert_eq!(clip.gap_ms(), 100);
        assert_eq!(clip.with_cel(1, |c| c.gap_ms), Some(10));
        assert_eq!(clip.with_cel(2, |c| c.rgba.is_empty() && c.encoded.is_some()), Some(true), "frames come encoded");
        assert!(clip.with_cel(3, |_| ()).is_none());
        // Asked for again: the same clip.
        assert_eq!(pics.header_picture(&path, 4, 4, true).unwrap().id(), clip.id());
        // More clips keep it, up to MAX_CLIPS; one more and the oldest is decoded afresh.
        let mut others = Vec::new();
        for i in 0..MAX_CLIPS {
            let other = dir.join(format!("hero{i}.png"));
            std::fs::copy(&path, &other).unwrap();
            let second = pics.header_picture(&other, 4, 4, true).unwrap();
            assert_ne!(second.id(), clip.id());
            others.push(other);
            if i + 1 < MAX_CLIPS {
                assert_eq!(pics.header_picture(&path, 4, 4, true).unwrap().id(), clip.id(), "still cached");
            }
        }
        assert_ne!(pics.header_picture(&path, 4, 4, true).unwrap().id(), clip.id(), "decoded afresh");
        // A plain PNG asked for as a clip is the still, shared with the plain request.
        let plain = dir.join("plain.png");
        {
            let f = std::fs::File::create(&plain).unwrap();
            let mut e = png::Encoder::new(std::io::BufWriter::new(f), 2, 2);
            e.set_color(png::ColorType::Rgba);
            e.set_depth(png::BitDepth::Eight);
            let mut wr = e.write_header().unwrap();
            wr.write_image_data(&[9u8; 16]).unwrap();
        }
        let a = pics.header_picture(&plain, 2, 2, true).unwrap();
        let b = pics.header_picture(&plain, 2, 2, false).unwrap();
        assert!(!a.is_animated());
        assert_eq!(a.id(), b.id());
        assert!(matches!(pics.lookup(&pics.header_key(&plain, 2, 2, true)), Lookup::Have(p) if p.id() == a.id()));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_complete_animated_picture_reads_its_frames_in_order() {
        let cels = vec![Cel::new(20, vec![1; 4]), Cel::new(30, vec![2; 4])];
        let p = Picture::animated(1, 1, vec![0; 4], 40, cels);
        assert!(p.is_animated() && p.complete());
        assert_eq!(p.gap_ms(), 40);
        assert_eq!(p.cel_count(), 2);
        assert_eq!(p.with_cel(1, |c| (c.gap_ms, c.rgba[0])), Some((30, 2)));
        assert_eq!(format!("{p:?}"), format!("Picture#{}(1x1)+2", p.id()));
    }

    #[test]
    fn lookup_and_failures() {
        let mut pics = Pictures::new();
        let key = Pictures::key(Path::new("/nonexistent/x.png"), 4, 4, Fit::Contain, None, false);
        assert!(matches!(pics.lookup(&key), Lookup::Missing));
        assert!(decode_file(&key).is_err());
        pics.note_failed(key.clone());
        assert!(matches!(pics.lookup(&key), Lookup::Failed));
        let d = Decoded { w: 1, h: 1, rgba: vec![0; 4], upload: None, clip: None, plain: false };
        let other = Pictures::key(Path::new("/x.png"), 1, 1, Fit::Contain, None, false);
        let p = pics.insert_decoded(other.clone(), d);
        assert!(matches!(pics.lookup(&other), Lookup::Have(q) if q.id() == p.id()));
    }
}
