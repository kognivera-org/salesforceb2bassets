/**
 * Shared state for Product Compare. Every compare component imports this module, so they all
 * see the same selection. The selection is kept in sessionStorage per store and buyer account,
 * which keeps it while the buyer navigates and for the rest of the browser session.
 */
import { getAppContext, getSessionContext } from 'commerce/contextApi';
import getConfig from '@salesforce/apex/ProductCompareController.getConfig';

const STORAGE_PREFIX = 'pcCompare';
const listeners = new Set();
let initPromise;
let storageKey;
let productIds = [];

/**
 * Loads the store context and the admin configuration once per page load.
 * Compare is only enabled for logged-in buyers.
 * @returns {Promise<{ context: { webstoreId: string, effectiveAccountId: string }, config: object }>}
 */
export function init() {
    if (!initPromise) {
        initPromise = Promise.all([getAppContext(), getSessionContext()])
            .then(async ([app, session]) => {
                const context = {
                    webstoreId: app?.webstoreId,
                    effectiveAccountId: session?.effectiveAccountId
                };
                storageKey = `${STORAGE_PREFIX}:${context.webstoreId}:${context.effectiveAccountId}`;
                productIds = read();
                const config = await getConfig({ webstoreId: context.webstoreId });
                return {
                    context,
                    config: { ...config, enabled: Boolean(config?.enabled && session?.isLoggedIn) }
                };
            })
            .catch((error) => {
                initPromise = undefined;
                throw error;
            });
    }
    return initPromise;
}

export function getProductIds() {
    return [...productIds];
}

export function hasProduct(productId) {
    return productIds.includes(productId);
}

/**
 * @returns {boolean} false when the compare limit is reached
 */
export function addProduct(productId, maxProducts) {
    if (!productId || productIds.includes(productId)) {
        return true;
    }
    if (productIds.length >= maxProducts) {
        return false;
    }
    save([...productIds, productId]);
    return true;
}

export function removeProduct(productId) {
    if (productIds.includes(productId)) {
        save(productIds.filter((id) => id !== productId));
    }
}

export function removeProducts(idsToRemove) {
    const remaining = productIds.filter((id) => !idsToRemove.includes(id));
    if (remaining.length !== productIds.length) {
        save(remaining);
    }
}

export function clearProducts() {
    save([]);
}

/**
 * @param {(productIds: string[]) => void} callback called whenever the selection changes
 * @returns {() => void} unsubscribe function
 */
export function subscribe(callback) {
    listeners.add(callback);
    return () => listeners.delete(callback);
}

function read() {
    try {
        const stored = JSON.parse(sessionStorage.getItem(storageKey));
        return Array.isArray(stored) ? stored : [];
    } catch (e) {
        return [];
    }
}

function save(ids) {
    productIds = ids;
    try {
        sessionStorage.setItem(storageKey, JSON.stringify(ids));
    } catch (e) {
        // Storage can be blocked (e.g. private browsing); the selection still works for this page.
    }
    listeners.forEach((callback) => callback(getProductIds()));
}
