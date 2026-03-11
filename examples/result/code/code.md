relationship between the beans. The only difference from previous exercises is the change in the JNDI name element tag for the Address home interface:

<local-indi-name>AddressHomeLocal</local-indi-name>

Because the Home interface for the Address is local, the tag is <local-jndi-name> rather than <jndi-name>.

the weblogic-emp-rdbms-jar.xml descriptor file contains a number of new sections and elements in this exercise. A detailed examination of the relationship elements will wait until the next

The file contains a section mapping the Address <comp-field> attributes from the `ebj-jar.xml` file to the database columns that correspond to a new section related to the address. For the primary key values in this base

```xml

<weblogic-rdbms-bean>

  <ejb-name>AddressJDBC</ejb-name>

  <data-source>name>Titan-dataSource</data-source-name>

  <table-name>ADDRESS</table-name>

  <field-map>

    <cmp-field>id</cmp-field>

    <dbms-column>ID</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>street</cmp-field>

    <dbms-column>STREET</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>city</cmp-field>

    <dbms-column>CITY</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>state</cmp-field>

    <dbms-column>STATE</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>zip</cmp-field>

    <dbms-column>ZIP</dbms-column>

  </field-map>

  <!-- Automatically generate the value of ID in the database on

inserts using sequence table -->

  <automatic-key-generation>

    <generator-type>NAMED SEQUENCE TABLE</generator-type>

    <generator-name>ADDRESS SEQUENCE</generator-name>

    <key-cache-size>10</key-cache-size>

  </automatic-key-generation>

</weblogic-rdbms-bean>

```
