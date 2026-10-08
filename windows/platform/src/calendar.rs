use crate::storage::Result;
use chrono::{DateTime, Duration, NaiveDate, Offset, TimeZone, Timelike, Utc};
use chrono_tz::Tz;
use serde::Serialize;

#[derive(Clone, Serialize)]
pub struct Interval {
    pub start: f64,
    pub end: f64,
}

pub fn date(ms: f64) -> Result<DateTime<Utc>> {
    if !ms.is_finite() {
        return Err("Invalid observation time.".into());
    }
    Utc.timestamp_millis_opt(ms as i64)
        .single()
        .ok_or("Invalid observation time.".into())
}

fn offset(at: i64, zone: Tz) -> Result<i32> {
    Ok(date(at as f64)?
        .with_timezone(&zone)
        .offset()
        .fix()
        .local_minus_utc())
}

// Split even non-hour transitions (for example Lord Howe's half-hour DST).
fn transition(mut low: i64, mut high: i64, zone: Tz) -> Result<i64> {
    let before = offset(low, zone)?;
    while high - low > 1 {
        let middle = low + (high - low) / 2;
        if offset(middle, zone)? == before {
            low = middle;
        } else {
            high = middle;
        }
    }
    Ok(high)
}

pub fn hour(ms: f64, zone: Tz) -> Result<Interval> {
    let at = date(ms)?.with_timezone(&zone);
    let instant = at.timestamp_millis();
    let elapsed = i64::from(at.minute()) * 60_000
        + i64::from(at.second()) * 1000
        + i64::from(at.timestamp_subsec_millis());
    let mut start = instant - elapsed;
    let mut end = start + 3_600_000;
    if offset(start, zone)? != offset(instant, zone)? {
        start = transition(start, instant, zone)?;
    }
    if offset(instant, zone)? != offset(end - 1, zone)? {
        end = transition(instant, end - 1, zone)?;
    }
    Ok(Interval {
        start: start as f64,
        end: end as f64,
    })
}

pub fn day(day: NaiveDate, zone: Tz) -> Result<Interval> {
    fn boundary(day: NaiveDate, zone: Tz) -> Result<i64> {
        let midnight = day.and_hms_opt(0, 0, 0).ok_or("Invalid reporting day.")?;
        // Midnight itself can be skipped, or an entire reporting date absent.
        for minute in 0..=1440 {
            if let Some(at) = zone
                .from_local_datetime(&(midnight + Duration::minutes(minute)))
                .earliest()
            {
                return Ok(at.timestamp_millis());
            }
        }
        Err("The reporting day could not be resolved.".into())
    }
    Ok(Interval {
        start: boundary(day, zone)? as f64,
        end: boundary(day.succ_opt().ok_or("Invalid reporting day.")?, zone)? as f64,
    })
}

pub fn hours(interval: &Interval, zone: Tz) -> Result<Vec<Interval>> {
    let mut result = Vec::new();
    let mut cursor = interval.start;
    while cursor < interval.end {
        let end = hour(cursor, zone)?.end.min(interval.end);
        result.push(Interval { start: cursor, end });
        cursor = end;
    }
    Ok(result)
}
