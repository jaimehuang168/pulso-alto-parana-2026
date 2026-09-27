/** Technical state is intentionally not displayed in the work interface. */
export const isCompanyAdmin=b=>b?.actor?.role==='admin'&&b.actor.is_super_admin===false;
export function readinessCard(){return '';}
