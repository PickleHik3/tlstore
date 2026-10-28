//! Details: the transcript of the last job (`<home>/.cache/tlstore/last-job.log`) as plain
//! wrapped lines under the header of the item the Installing screen showed. It scrolls like
//! the item page. When the engine knew a fix the file starts `To fix:` and the command on the
//! next line; `c` copies that command.

use crate::layout;
use crate::render::{Rect, Style};
use crate::term::{Event, Key, MouseKind};

use super::paint::{draw_header, HeaderContent, Masthead, Paint, Slot, Slots, A_BACK, A_CONTEXT};
use super::scene::El;
use super::{Go, Store, View};

/// What the page says when there is no transcript.
pub const NONE: &str = "No transcript from the last job.";

/// The transcript, split into the fix command (when it has one) and the narration.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Transcript {
    pub fix: Option<String>,
    pub lines: Vec<String>,
}

impl Transcript {
    pub fn parse(text: &str) -> Transcript {
        let mut lines: Vec<&str> = text.lines().collect();
        let mut fix = None;
        if lines.first().is_some_and(|l| l.trim() == "To fix:") && lines.len() >= 2 {
            fix = Some(lines[1].trim().to_string()).filter(|c| !c.is_empty());
            lines.drain(..2);
            if lines.first().is_some_and(|l| l.trim().is_empty()) {
                lines.remove(0);
            }
        }
        Transcript { fix, lines: lines.into_iter().map(|l| l.trim_end().to_string()).collect() }
    }

    fn is_empty(&self) -> bool {
        self.fix.is_none() && self.lines.iter().all(|l| l.trim().is_empty())
    }
}

pub struct Details {
    name: String,
    transcript: Transcript,
    scroll: u16,
    content_h: u16,
    view_h: u16,
    drag: Option<(u16, u16)>,
}

impl Details {
    pub fn new(st: &Store) -> Details {
        let name = st.job.as_ref().map(|j| j.shown_name()).unwrap_or_default();
        let path = st.home.join(".cache/tlstore/last-job.log");
        let text = std::fs::read(&path).map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
        Details { name, transcript: Transcript::parse(&text), scroll: 0, content_h: 0, view_h: 0, drag: None }
    }

    fn max_scroll(&self) -> u16 {
        self.content_h.saturating_sub(self.view_h)
    }

    fn scroll_by(&mut self, d: i32) {
        self.scroll = (self.scroll as i32 + d).clamp(0, self.max_scroll() as i32) as u16;
    }
}

/// The element for the next block on screen (off screen ones are not animated).
fn next_el(p: &Paint, k: &mut u16, y: u16) -> El {
    if p.row(y).is_some() {
        *k += 1;
        El::Block(*k - 1)
    } else {
        El::Block(u16::MAX)
    }
}

impl View for Details {
    fn name(&self) -> &'static str {
        "details"
    }

    fn draw(&mut self, p: &mut Paint, st: &mut Store) {
        let pal = *p.f.pal();
        let cols = p.f.cols();
        let info = st.cat.info(&self.name).clone();
        let hdr = layout::header(cols, p.f.rows(), 7, None);
        let content = HeaderContent {
            masthead: Masthead::Page { repo: info.upstream().map(str::to_string), setup: info.setup() },
            picture: None,
            name: &self.name,
            standfirst: info.standfirst(),
            facts: st.facts(&self.name, Some("failed")),
        };
        self.view_h = hdr.notice;
        p.clip = Some(Rect::new(0, 0, cols, hdr.notice));
        p.scroll = self.scroll;
        draw_header(p, &hdr, &content);

        let b = hdr.body;
        let mut y = b.y;
        let mut k: u16 = 0;
        if self.transcript.is_empty() {
            let e = next_el(p, &mut k, y);
            p.text_clip(e, b.x, y, &layout::fit_line(NONE, b.w), pal.dim_s().italic(), b.right());
            y += 1;
        } else {
            if let Some(cmd) = &self.transcript.fix {
                let e = next_el(p, &mut k, y);
                p.text_clip(e, b.x, y, "To fix:", pal.accent_s().bold(), b.right());
                y += 1;
                for line in layout::wrap(cmd, b.w.saturating_sub(2), usize::MAX) {
                    let e = next_el(p, &mut k, y);
                    p.fill(e, Rect::new(b.x, y, b.w, 1), Style::new().bg(pal.tonal));
                    p.text_clip(e, b.x + 1, y, &line, pal.tonal_s(), b.right());
                    y += 1;
                }
                y += 1;
            }
            for raw in &self.transcript.lines {
                if raw.trim().is_empty() {
                    y += 1;
                    continue;
                }
                for line in layout::wrap(raw, b.w, usize::MAX) {
                    let e = next_el(p, &mut k, y);
                    p.text_clip(e, b.x, y, &line, pal.ink_s(), b.right());
                    y += 1;
                }
            }
        }
        self.content_h = y;
        self.scroll = self.scroll.min(self.max_scroll());
        p.clip = None;
        p.scroll = 0;
    }

    fn keys(&self, _st: &mut Store) -> Slots {
        [
            self.transcript.fix.as_ref().map(|_| Slot::new("c", "copy", Key::Char('c'))),
            None,
            None,
            None,
            Some(Slot::new("esc", "back", Key::Esc)),
        ]
    }

    fn handle(&mut self, ev: &Event, st: &mut Store) -> Go {
        let page = self.view_h.saturating_sub(2).max(1) as i32;
        match ev {
            Event::Key(Key::Up | Key::Char('k')) => self.scroll_by(-1),
            Event::Key(Key::Down | Key::Char('j')) => self.scroll_by(1),
            Event::Key(Key::PageUp) => self.scroll_by(-page),
            Event::Key(Key::PageDown) => self.scroll_by(page),
            Event::Key(Key::Home) => self.scroll = 0,
            Event::Key(Key::End) => self.scroll = self.max_scroll(),
            Event::Key(Key::Esc | Key::Backspace | Key::Left) | Event::Tap { action: A_BACK, .. } => {
                return Go::Back
            }
            Event::Key(Key::Char('c')) => {
                if let Some(cmd) = self.transcript.fix.clone() {
                    st.env.copy(&cmd);
                    st.notice = Some("copied".into());
                }
            }
            Event::Tap { action: A_CONTEXT, .. } => {}
            Event::Mouse(m) => match m.kind {
                MouseKind::ScrollDown => self.scroll_by(3),
                MouseKind::ScrollUp => self.scroll_by(-3),
                MouseKind::Press => self.drag = Some((m.row, self.scroll)),
                MouseKind::Drag => {
                    if let Some((row0, s0)) = self.drag {
                        let s = s0 as i32 + row0 as i32 - m.row as i32;
                        self.scroll = s.clamp(0, self.max_scroll() as i32) as u16;
                    }
                }
                MouseKind::Release => self.drag = None,
                _ => {}
            },
            Event::Key(_) => return Go::Pass,
            _ => {}
        }
        Go::Stay
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fix_head_is_split_off() {
        let t = Transcript::parse("To fix:\npacman -S --overwrite '*' pcre2 ripgrep\n\nerror: failed\nsecond\n");
        assert_eq!(t.fix.as_deref(), Some("pacman -S --overwrite '*' pcre2 ripgrep"));
        assert_eq!(t.lines, vec!["error: failed", "second"]);
        let t = Transcript::parse("just narration\n");
        assert_eq!((t.fix, t.lines), (None, vec!["just narration".to_string()]));
        assert!(Transcript::parse("").is_empty());
    }
}
