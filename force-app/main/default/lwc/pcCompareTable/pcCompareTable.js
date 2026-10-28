import { LightningElement, api, wire } from 'lwc';
import { navigate, NavigationContext } from 'lightning/navigation';
import { addItemToCart } from 'commerce/cartApi';
import { getProductInventoryCollection } from 'commerce/productApi';
import LOCALE from '@salesforce/i18n/locale';
import getCompareData from '@salesforce/apex/ProductCompareController.getCompareData';
import addToList from '@salesforce/apex/ProductCompareController.addToList';
import { init, getProductIds, removeProduct, removeProducts, subscribe } from 'c/pcCompareService';

/**
 * Side-by-side comparison of the selected products. Place it on a dedicated compare page.
 */
export default class PcCompareTable extends LightningElement {
    @api title = 'Compare Products';
    @api emptyMessage = 'You have not selected any products to compare.';
    @api showAddToCart = false;
    @api showAddToList = false;
    @api addToCartText = 'Add to cart';
    @api addToListText = 'Add to list';
    @api outOfStockText = 'Out of stock';

    @wire(NavigationContext)
    navContext;

    enabled = false;
    loading = true;
    error;
    context;
    config;
    products = [];
    quantities = {};
    statusById = {};
    unsubscribe;

    get hasProducts() {
        return this.products.length > 0;
    }

    get showEmpty() {
        return this.enabled && !this.loading && !this.error && !this.hasProducts;
    }

    get showTable() {
        return this.enabled && !this.loading && this.hasProducts;
    }

    get showActions() {
        return this.showAddToCart || this.showAddToList;
    }

    get columns() {
        return this.products.map((product) => {
            const outOfStock = product.inStock === false;
            return {
                id: product.id,
                name: product.name,
                sku: product.sku,
                imageUrl: product.imageUrl,
                quantity: this.quantities[product.id] ?? 1,
                outOfStock,
                addToCartLabel: outOfStock ? this.outOfStockText : this.addToCartText,
                status: this.statusById[product.id],
                removeLabel: `Remove ${product.name} from compare`
            };
        });
    }

    get rows() {
        const rows = [
            { key: 'sku', label: 'SKU', cells: this.cells((p) => p.sku) },
            { key: 'price', label: 'Price', cells: this.cells((p) => this.formatPrice(p)) }
        ];
        if (this.config.showAvailability) {
            rows.push({
                key: 'availability',
                label: 'Availability',
                cells: this.cells(
                    (p) => p.availability,
                    (p) => (p.inStock === false ? 'stock stock_out' : p.inStock ? 'stock stock_in' : '')
                )
            });
        }
        (this.config.attributes || []).forEach((attribute) => {
            rows.push({
                key: `attr-${attribute.fieldName}`,
                label: attribute.label,
                cells: this.cells((p) => p.attributeValues?.[attribute.fieldName])
            });
        });
        return rows;
    }

    cells(getValue, getClass) {
        return this.products.map((product) => {
            const value = getValue(product);
            return {
                key: product.id,
                value: value === null || value === undefined || value === '' ? '—' : value,
                className: getClass ? getClass(product) : ''
            };
        });
    }

    formatPrice(product) {
        if (product.unitPrice === null || product.unitPrice === undefined) {
            return null;
        }
        try {
            return new Intl.NumberFormat(LOCALE, {
                style: 'currency',
                currency: product.currencyIsoCode || 'USD'
            }).format(product.unitPrice);
        } catch (e) {
            return String(product.unitPrice);
        }
    }

    connectedCallback() {
        this.unsubscribe = subscribe((ids) => {
            // Keep the table in step with removals made here or in the tray.
            this.products = this.products.filter((product) => ids.includes(product.id));
        });
        init()
            .then(({ context, config }) => {
                this.context = context;
                this.config = config;
                this.enabled = config.enabled;
                return this.enabled ? this.load() : undefined;
            })
            .catch(() => {
                this.enabled = false;
            })
            .finally(() => {
                this.loading = false;
            });
    }

    disconnectedCallback() {
        if (this.unsubscribe) {
            this.unsubscribe();
        }
    }

    load() {
        const ids = getProductIds();
        if (ids.length === 0) {
            this.products = [];
            return Promise.resolve();
        }
        this.error = undefined;
        return getCompareData({
            webstoreId: this.context.webstoreId,
            effectiveAccountId: this.context.effectiveAccountId,
            productIds: ids
        })
            .then((products) => {
                this.products = products;
                // Drop products the buyer is not entitled to see.
                const returnedIds = new Set(products.map((product) => product.id));
                removeProducts(ids.filter((id) => !returnedIds.has(id)));
                return this.applyInventory(products.map((product) => product.id));
            })
            .catch((error) => {
                this.error = error?.body?.message || 'Unable to load products for comparison.';
            });
    }

    /**
     * Sets stock status from the storefront inventory service, the same buyer-facing source the
     * product page uses. If it can't be read, the status from Apex (if any) is kept.
     */
    applyInventory(productIds) {
        if (productIds.length === 0) {
            return Promise.resolve();
        }
        return getProductInventoryCollection({ productIds })
            .then((data) => {
                if (!data?.success) {
                    return;
                }
                // Compare on the 15-character Id so 15- and 18-character forms match.
                const availableById = new Map();
                (data.totalInventory || []).forEach((item) => {
                    availableById.set(String(item.product2Id).slice(0, 15), item.availableToOrder);
                    (item.variants || []).forEach((variant) => {
                        availableById.set(String(variant.product2Id).slice(0, 15), variant.availableToOrder);
                    });
                });
                this.products = this.products.map((product) => {
                    const key = product.id.slice(0, 15);
                    if (!availableById.has(key)) {
                        return product;
                    }
                    const inStock = Number(availableById.get(key)) > 0;
                    return { ...product, inStock, availability: inStock ? 'In stock' : 'Out of stock' };
                });
            })
            .catch(() => {
                // Keep the Apex status; the table still works without stock data.
            });
    }

    handleRemove(event) {
        removeProduct(event.currentTarget.dataset.id);
    }

    handleQuantityChange(event) {
        const quantity = parseInt(event.target.value, 10);
        this.quantities = {
            ...this.quantities,
            [event.target.dataset.id]: Number.isNaN(quantity) || quantity < 1 ? 1 : quantity
        };
    }

    handleAddToCart(event) {
        const productId = event.currentTarget.dataset.id;
        if (this.products.find((product) => product.id === productId)?.inStock === false) {
            this.setStatus(productId, 'This product is out of stock.', true);
            return;
        }
        const quantity = this.quantities[productId] ?? 1;
        // Calls the cart directly: the compare page has no Commerce action handler to catch dispatched actions.
        this.setStatus(productId, 'Adding…', false);
        addItemToCart(productId, quantity)
            .then(() => this.setStatus(productId, 'Added to cart.', false))
            .catch((error) =>
                this.setStatus(productId, error?.message || error?.body?.message || 'Could not add to cart.', true)
            );
    }

    handleAddToList(event) {
        const productId = event.currentTarget.dataset.id;
        addToList({
            webstoreId: this.context.webstoreId,
            effectiveAccountId: this.context.effectiveAccountId,
            productId
        })
            .then(() => this.setStatus(productId, 'Added to list.', false))
            .catch((error) => this.setStatus(productId, error?.body?.message || 'Could not add to list.', true));
    }

    handleProductClick(event) {
        event.preventDefault();
        if (this.navContext) {
            navigate(this.navContext, {
                type: 'standard__recordPage',
                attributes: {
                    objectApiName: 'Product2',
                    recordId: event.currentTarget.dataset.id,
                    actionName: 'view'
                }
            });
        }
    }

    setStatus(productId, text, isError) {
        this.statusById = {
            ...this.statusById,
            [productId]: { text, className: isError ? 'status status_error' : 'status status_success' }
        };
    }
}
