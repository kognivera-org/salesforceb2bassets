import { LightningElement, api, wire } from 'lwc';
import { navigate, NavigationContext } from 'lightning/navigation';
import LOCALE from '@salesforce/i18n/locale';
import checkCategory from '@salesforce/apex/ProductCompareController.checkCategory';
import { init, addProduct, removeProduct, getProductIds, subscribe } from 'c/pcCompareService';

const POPUP_WIDTH = 288;
const VIEWPORT_GUTTER = 16;

/**
 * "Compare" checkbox for a single product. On the product detail page it reads the record Id
 * from the page; inside a product card the card passes product-id.
 * In category mode, a product from another category is blocked and a popup suggests products
 * from the compare category instead.
 */
export default class PcCompareButton extends LightningElement {
    /** Set by Experience Builder on the product detail page. */
    @api recordId;
    /** Set by a parent component, e.g. a product card. Takes precedence over recordId. */
    @api productId;
    @api label = 'Compare';
    @api limitMessage = 'You can compare up to {0} products. Remove a product to add another.';
    @api categoryMessage = 'Only products from {0} can be compared together.';
    @api categoryFallbackMessage = 'This product can’t be compared with the products you selected.';
    @api suggestionsTitle = 'Compare these instead';
    @api suggestionButtonText = 'Compare';

    @wire(NavigationContext)
    navContext;

    enabled = false;
    categoryMode = false;
    maxProducts = 0;
    context;
    selectedIds = [];
    message;
    checking = false;
    popup;
    popupStyle = '';
    unsubscribe;
    closeOnScroll = () => this.closePopup();

    get resolvedProductId() {
        return this.productId || this.recordId;
    }

    get checked() {
        return this.selectedIds.includes(this.resolvedProductId);
    }

    get showButton() {
        return this.enabled && Boolean(this.resolvedProductId);
    }

    get suggestions() {
        return (this.popup?.suggestions || []).map((suggestion) => ({
            ...suggestion,
            price: this.formatPrice(suggestion),
            compareLabel: `${this.suggestionButtonText} ${suggestion.name}`
        }));
    }

    get hasSuggestions() {
        return this.suggestions.length > 0;
    }

    connectedCallback() {
        this.unsubscribe = subscribe((ids) => {
            this.selectedIds = ids;
            this.message = undefined;
        });
        init()
            .then(({ context, config }) => {
                this.context = context;
                this.enabled = config.enabled;
                this.categoryMode = config.categoryMode === true;
                this.maxProducts = config.maxProducts;
                this.selectedIds = getProductIds();
            })
            .catch(() => {
                this.enabled = false;
            });
    }

    disconnectedCallback() {
        if (this.unsubscribe) {
            this.unsubscribe();
        }
        window.removeEventListener('scroll', this.closeOnScroll);
    }

    handleChange(event) {
        const checkbox = event.target;
        const productId = this.resolvedProductId;
        this.closePopup();
        if (!checkbox.checked) {
            removeProduct(productId);
            return;
        }
        const selected = getProductIds();
        if (selected.length >= this.maxProducts) {
            checkbox.checked = false;
            this.showLimitMessage();
            return;
        }
        if (!this.categoryMode || selected.length === 0) {
            this.add(productId, checkbox);
            return;
        }
        // Stay unticked until the category check passes.
        checkbox.checked = false;
        this.checking = true;
        checkCategory({
            webstoreId: this.context.webstoreId,
            effectiveAccountId: this.context.effectiveAccountId,
            productId,
            selectedIds: selected
        })
            .then((result) => {
                if (result?.allowed !== false) {
                    this.add(productId, checkbox);
                    return;
                }
                this.openPopup(checkbox, result);
            })
            .catch(() => {
                // If the check can't run, don't block the buyer.
                this.add(productId, checkbox);
            })
            .finally(() => {
                this.checking = false;
            });
    }

    add(productId, checkbox) {
        if (addProduct(productId, this.maxProducts)) {
            checkbox.checked = true;
        } else {
            checkbox.checked = false;
            this.showLimitMessage();
        }
    }

    showLimitMessage() {
        this.message = this.limitMessage.replace('{0}', this.maxProducts);
    }

    openPopup(anchor, result) {
        this.popup = {
            message: result.categoryName
                ? this.categoryMessage.replace('{0}', result.categoryName)
                : this.categoryFallbackMessage,
            suggestions: result.suggestions || []
        };
        // Fixed position so a product card's overflow can't clip the popup.
        const rect = anchor.getBoundingClientRect();
        const width = Math.min(POPUP_WIDTH, window.innerWidth - VIEWPORT_GUTTER * 2);
        const left = Math.max(VIEWPORT_GUTTER, Math.min(rect.left, window.innerWidth - width - VIEWPORT_GUTTER));
        window.addEventListener('scroll', this.closeOnScroll, { passive: true });
        this.popupStyle = `top: ${rect.bottom + 6}px; left: ${left}px; width: ${width}px;`;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => this.template.querySelector('.popup-close')?.focus());
    }

    closePopup() {
        this.popup = undefined;
        window.removeEventListener('scroll', this.closeOnScroll);
    }

    handlePopupKeydown(event) {
        if (event.key === 'Escape') {
            this.closePopup();
            this.template.querySelector('.compare-checkbox')?.focus();
        }
    }

    handleSuggestionCompare(event) {
        const productId = event.currentTarget.dataset.id;
        if (addProduct(productId, this.maxProducts)) {
            this.popup = {
                ...this.popup,
                suggestions: this.popup.suggestions.filter((suggestion) => suggestion.id !== productId)
            };
        } else {
            this.closePopup();
            this.showLimitMessage();
        }
    }

    handleSuggestionOpen(event) {
        event.preventDefault();
        const recordId = event.currentTarget.dataset.id;
        this.closePopup();
        if (this.navContext) {
            navigate(this.navContext, {
                type: 'standard__recordPage',
                attributes: { objectApiName: 'Product2', recordId, actionName: 'view' }
            });
        }
    }

    handleClick(event) {
        // Keep clicks inside a product card from navigating to the product page.
        event.stopPropagation();
    }

    formatPrice(suggestion) {
        if (suggestion.unitPrice === null || suggestion.unitPrice === undefined) {
            return null;
        }
        try {
            return new Intl.NumberFormat(LOCALE, {
                style: 'currency',
                currency: suggestion.currencyIsoCode || 'USD'
            }).format(suggestion.unitPrice);
        } catch (e) {
            return String(suggestion.unitPrice);
        }
    }
}
