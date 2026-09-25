/**
 * Display only. Never changes captured_at, received_at or authorization timestamps.
 * Paraguay stopped clock changes after 2024-10-06 (IANA tzdb 2025a).
 * Some browser/OS tzdb copies still apply the former winter -04 in September 2026.
 * Etc/GMT+3 is the IANA fixed-offset zone UTC-03: the POSIX sign is intentionally reversed.
 * Keep the historical regional rules for dates before the last transition.
 * Sources: https://www.iana.org/time-zones/releases/2025a ; https://aravo.intn.gov.py/
 */
const LAST_TRANSITION=Date.parse('2024-10-06T04:00:00Z');
export function formatAsuncion(value,options={}){
 const date=value instanceof Date?value:new Date(value);
 if(!Number.isFinite(date.getTime()))throw new RangeError('Invalid date');
 const timeZone=date.getTime()>=LAST_TRANSITION?'Etc/GMT+3':'America/Asuncion';
 return new Intl.DateTimeFormat('es-PY',{...options,timeZone}).format(date);
}
