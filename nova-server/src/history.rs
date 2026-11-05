//! Historia para las gráficas: 30 min a 5 s por muestra y 24 h a 1 min (media de cada minuto).

use crate::model::Series;
use crate::sys::now_secs;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs;

pub type Point = (u64, Option<f64>, Option<f64>, Option<f64>);

const SHORT_LEN: usize = 30 * 60 / 5;
const LONG_LEN: usize = 24 * 60;

#[derive(Default, Serialize, Deserialize)]
pub struct History {
    short: VecDeque<Point>,
    long: VecDeque<Point>,
    #[serde(skip)]
    bucket: Vec<Point>,
    #[serde(skip)]
    bucket_minute: Option<u64>,
}

fn push(queue: &mut VecDeque<Point>, point: Point, cap: usize) {
    queue.push_back(point);
    while queue.len() > cap {
        queue.pop_front();
    }
}

fn mean(values: impl Iterator<Item = Option<f64>>) -> Option<f64> {
    let vals: Vec<f64> = values.flatten().collect();
    (!vals.is_empty()).then(|| (vals.iter().sum::<f64>() / vals.len() as f64 * 10.0).round() / 10.0)
}

impl History {
    pub fn load(path: &str) -> Self {
        let mut h: History = fs::read_to_string(path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let now = now_secs();
        h.short.retain(|p| p.0 + 30 * 60 >= now);
        h.long.retain(|p| p.0 + 24 * 3600 >= now);
        h
    }

    pub fn save(&self, path: &str) {
        let Ok(json) = serde_json::to_string(self) else { return };
        let tmp = format!("{path}.tmp");
        if fs::write(&tmp, json).is_ok() {
            let _ = fs::rename(&tmp, path);
        }
    }

    pub fn add(&mut self, point: Point) {
        push(&mut self.short, point, SHORT_LEN);
        let minute = point.0 / 60;
        if let Some(current) = self.bucket_minute {
            if minute != current && !self.bucket.is_empty() {
                let b = std::mem::take(&mut self.bucket);
                let avg = (
                    current * 60,
                    mean(b.iter().map(|p| p.1)),
                    mean(b.iter().map(|p| p.2)),
                    mean(b.iter().map(|p| p.3)),
                );
                push(&mut self.long, avg, LONG_LEN);
            }
        }
        self.bucket_minute = Some(minute);
        self.bucket.push(point);
    }

    pub fn series(&self, long: bool) -> Series {
        let points = if long { &self.long } else { &self.short };
        let mut s = Series::default();
        for p in points {
            s.t.push(p.0);
            s.cpu.push(p.1);
            s.temp.push(p.2);
            s.power.push(p.3);
        }
        s
    }
}
