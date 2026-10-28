import { LightningElement, api, wire } from 'lwc';
import { navigate, NavigationContext } from 'lightning/navigation';
import getCompareData from '@salesforce/apex/ProductCompareController.getCompareData';
import getCompareCategoryName from '@salesforce/apex/ProductCompareController.getCompareCategoryName';
import { init, getProductIds, removeProduct, removeProducts, clearProducts, subscribe } from 'c/pcCompareService';

/**
 * Bar fixed to the bottom of every page that lists the products selected for comparison.
 * Place it in the theme layout (e.g. the footer) so it appears on all pages.
 */
export default class PcCompareTray extends LightningElement {
    @api title = 'Compare Products';
    @api compareButtonText = 'Compare';
    @api clearAllText = 'Clear all';
    /** API name of the Experience Builder page that holds the Product Compare Table. */
    @api comparePageApiName = 'Compare__c';
    /** Shown before the compare category in category mode. */
    @api categoryPrefix = 'Comparing:';

    @wire(NavigationContext)
    navContext;

    enabled = false;
    maxProducts = 0;
    categoryMode = false;
    categoryName;
    categoryForId;
    context;
    productIds = [];
    productsById = {};
    expanded = false;
    unsubscribe;

    get showTray() {
        return this.enabled && this.productIds.length > 0;
    }

    get items() {
        return this.productIds.map((id) => {
            const product = this.productsById[id];
            return {
                id,
                name: product?.name ?? '',
                imageUrl: product?.imageUrl,
                removeLabel: `Remove ${product?.name ?? 'product'} from compare`
            };
        });
    }

    get countText() {
        return `${this.productIds.length} / ${this.maxProducts}`;
    }

    get categoryText() {
        return this.categoryMode && this.categoryName ? `${this.categoryPrefix} ${this.categoryName}` : null;
    }

    get compareDisabled() {
        return this.productIds.length < 2;
    }

    get compareLabel() {
        return `${this.compareButtonText} (${this.productIds.length})`;
    }

    get trayClass() {
        return this.expanded ? 'tray tray_expanded' : 'tray';
    }

    get toggleLabel() {
        return this.expanded ? 'Hide selected products' : 'Show selected products';
    }

    connectedCallback() {
        this.unsubscribe = subscribe((ids) => this.update(ids));
        init()
            .then(({ context, config }) => {
                this.context = context;
                this.enabled = config.enabled;
                this.maxProducts = config.maxProducts;
                this.categoryMode = config.categoryMode === true;
                this.update(getProductIds());
            })
            .catch(() => {
                this.enabled = false;
            });
    }

    disconnectedCallback() {
        if (this.unsubscribe) {
            this.unsubscribe();
        }
    }

    update(ids) {
        this.productIds = ids;
        if (!this.enabled) {
            return;
        }
        this.updateCategory(ids[0]);
        const missing = ids.filter((id) => !this.productsById[id]);
        if (missing.length === 0) {
            return;
        }
        getCompareData({
            webstoreId: this.context.webstoreId,
            effectiveAccountId: this.context.effectiveAccountId,
            productIds: missing
        })
            .then((products) => {
                const loaded = { ...this.productsById };
                products.forEach((product) => {
                    loaded[product.id] = product;
                });
                this.productsById = loaded;
                // Drop products the buyer is not entitled to see.
                const returnedIds = new Set(products.map((product) => product.id));
                removeProducts(missing.filter((id) => !returnedIds.has(id)));
            })
            .catch(() => {
                // Names and images stay blank; the compare page shows any error.
            });
    }

    /** The first selected product sets the compare category, so it is looked up again only when that product changes. */
    updateCategory(firstId) {
        if (!this.categoryMode || firstId === this.categoryForId) {
            return;
        }
        this.categoryForId = firstId;
        this.categoryName = undefined;
        if (!firstId) {
            return;
        }
        getCompareCategoryName({ webstoreId: this.context.webstoreId, productId: firstId })
            .then((name) => {
                if (this.categoryForId === firstId) {
                    this.categoryName = name;
                }
            })
            .catch(() => {
                // The tray works without the category name.
            });
    }

    handleRemove(event) {
        removeProduct(event.currentTarget.dataset.id);
    }

    handleClearAll() {
        clearProducts();
        this.expanded = false;
    }

    handleToggle() {
        this.expanded = !this.expanded;
    }

    handleCompare() {
        if (this.navContext) {
            navigate(this.navContext, {
                type: 'comm__namedPage',
                attributes: { name: this.comparePageApiName }
            });
        }
    }
}
